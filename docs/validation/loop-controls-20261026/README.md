# Dependency ordering and correction-loop control — 2026-10-26

This record covers software changes after the matched actuator-response replay.
The live RTC and GUI retain their original invocation IDs/PIDs, both active;
see `live-service-check.txt`. No deployment or live command was performed.

## Delivered behavior

AOS derives a stable topological order from direct links during cold
preparation. Declaration order breaks ties among ready nodes. Delayed links
remain explicit and do not constrain same-frame ordering; direct/self cycles
are rejected. The hot path remains a concrete, fixed, preallocated execution
sequence. Explicit grouped-stream configurations retain their existing stricter
group/declaration-order admission contract.

FGA correction/integrator and leaky-integrator plans expose runtime Boolean
`closed`, defaulting to true to preserve existing behavior. Opening holds the
committed correction and mathematical state, while frame processing, metadata,
acquisition and mandatory command exchange continue. Closing resumes the normal
feedback recurrence from retained state. Validation, rejection, local commit,
reset and anti-windup contracts remain in force. Downstream filters and physical
responses continue settling; opening does not imply a flat, zero command or
instantaneously frozen physical stage. There is no implicit reset or gain edit.

The GUI's optional `session.correction_loops` list binds presentation to an exact
graph/qualified Boolean property. Open/Close use existing RTC PropertiesSet,
owner-generation acknowledgement, readback and shared history. The GUI rechecks
the declaration, fresh session, connection generation, session ID, observed
Boolean and busy state. Submitted values do not become observations. Unknown
outcomes are retained without automatic retry. Classic and GPI source views
declare bindings; the current coupled GPI controller has one coordinated loop.

## Evidence

Implementation identities are AOS `859677b770e141c42c937d211cc9295cc1160d7d`,
JFG monorepo `2129caba197afce79b27513d1e1b0030602a08ae` and GUI
`699d00dad16384ef8aaa7f555a39ebb9dde50396`; instrument presentation bindings
are `6d4a9e3de34341edb5981363b416946ea6fefca9`. Source branches are based on the
previously validated actuator work; pre-existing source-channel edits in the
original RTC/instrument checkouts remain preserved and uncommitted on explicit
preservation branches, separate from the integrated main branches.

- AOS: the new scrambled response-chain test fails under the old ordering
  restriction. Focused algorithm-graph/response selectors pass 1,615 assertions
  across 45 testsets, including identity, cycle/delay, grouped execution,
  failure/reset, inference and zero-allocation checks. Independent exhaustive
  three-node ordering checks pass 1,074 assertions.
- Scientific controllers: the new open-state selector fails before the new
  property exists. Final CPU checks pass 403 assertions with no method
  ambiguities; ordinary graph checks pass 192, CUDA capture/replay 1,166 and
  PipeWire property staging/adoption 144. Open/close, held state/output,
  rejection/discard, reset, generations and zero allocation are covered.
- RTC: `test/test_correction_loop_control.jl` passes 39 assertions. It roundtrips
  the existing Boolean property command through the native serializer, runs the
  ordinary CPU scientific graph, holds through eight further frames and resumes
  the exact anti-windup recurrence. This is interface/software integration, not
  an actual native-daemon session test.
- GUI: 639 library, 284 application and 12 import tests pass, with 16 existing
  opt-in tests ignored. WASM/browser compilation and 151 Julia fixture checks
  pass. Browser fixtures pass 28 checks at each of two display scales, without
  browser errors. The initial system-Python invocation lacked Playwright;
  the existing cached GUI environment completed both checks. Browser fixtures
  do not demonstrate a live correction-loop transition.
- Strict Clippy reports six existing `chunks_exact_to_as_chunks` errors in
  unchanged DM files. The supplemental run with the documented baseline lint
  exceptions passes. The independent GUI review confirms no new source finding.

Logs, exact selector/environment notes and the three independent reviews are
retained here. Julia 1.13.2, CUDA.jl 6.4.2 and an RTX 3080 were used for the
reported scientific checks. No full scientific package matrix was run.
Console logs are retained as `.log.gz`; decompress before reading. The optional
RTC selector needs an environment containing the recorded JFG/FGA sources:

```sh
julia --startup-file=no --project=/path/to/science-environment test/test_correction_loop_control.jl
```

## Limits and next boundaries

Ordinary CPU JFG owners accept runtime updates. Captured JFG owners retain their
existing requirement to prepare a new owner to change properties; the supported
CUDA checks exercise prepared open/closed modes, not runtime capture mutation.
ClosedLoopIntegratorF32 did not gain a new GPU capture implementation.

Independent per-corrector closure, explicit flat/clear operations, bumpless
transfer, transition-frame reporting and physical-device fault policies need
separate contracts. The current hold/resume property does not establish them.
Authored instrument views containing owner references use the normal RTC cold
export path before GUI loading. No fresh exported application, native session,
hardware, AMDGPU execution, deadline or global-stability qualification is
claimed by these checks.

## Hsm adoption tracking follow-up

RTC 0.2.12 uses registered Hsm 0.3.2 for explicitly declared correction
properties, with the generic off-processing observer in FilterGraphPipeWire
0.1.8. The controller's native Boolean and generation contract remains
authoritative; this does not add another lifecycle authority or native status
property. See the [owner semantics](../../HEADLESS_RTC_DESIGN.md#rtc-correction-loop-adoption-tracking)
and [configuration](../../JULIA_DEPLOYMENT_USAGE.md#open-and-close-correction).

On Julia 1.13.2, the focused pure-machine selector passes 147 assertions and
the graph-owner/argument selector passes 56. The optional combined CPU selector
passes 25 assertions using real graph/native-filter objects and the actual
staging/adoption callbacks. It checks initial admission, pending versus applied
states, the native busy slot, opposite requests before queued readback,
same-value generation updates and missing/non-Boolean declarations. It does not
connect to a daemon or the live GPI2 session:

```sh
julia --project=. test/test_correction_loops.jl
julia --project=. test/test_graph_owner.jl
julia --project=/path/to/science-environment test/test_correction_observer.jl
```

The complete graph-adapter CPU suite passes 1,356 assertions across 62 testsets,
including default/captured paths, observer ordering and failure containment,
hold/resume, and zero-allocation processing with an observer configured. The
native SDK prefix is `pipewireao-classic-headless-20261021`; the source-validation
environment overrides only the reviewed JFG/RTC packages and uses registered
Hsm. Adapter source was reviewed at `cef55eb` against `acddfa2`.

The complete RTC workspace passes 4,465 assertions in 160 testsets using
`Pkg.test(; julia_args=["--threads=1"])` with the same native SDK environment.
The initial workspace run required adding Hsm as a direct test dependency for
the test's explicit `import Hsm`; the final run uses the committed workspace
dependency and compatibility declarations. Classic/GPI2 offline profile checks
pass 49 assertions, and both authored loop arguments match their GUI property
references. Changed YAML/TOML files pass their standalone formatters. The full
instrument formatting check still fails on unchanged
`gpi2/calibration/context.yaml` and `gpi2/rtc/calibration.yaml`; neither file was
modified for this increment.

A fresh environment built from GPI2's updated package pins resolves registry
RTC 0.2.12 (`f20210134f955c85a6c55242e94026cc1081c9df`), graph adapter 0.1.8
(`c47ce1915333d20e277ce40e1eb1700b644cc033`) and Hsm 0.3.2
(`1958e3af28cdc2d9a5baf15af376cbddcd85d606`), with no source overrides. The same
25-assertion combined selector passes against those installed releases.

Independent source review found no actionable defect in this observer-only
increment. A forbidden callback on another thread disables the adapter observer
before entering the RTC observer, leaving its last local state unchanged;
recovery from that lifecycle-contract violation is not established. Ordinary
native callbacks obey constructing-thread ownership. No observer or Hsm work
was added to frame processing.

The live CUDA GPI2 refresh remains on RTC 0.2.11 and the earlier graph adapter;
its independently verified [live receipt](../yaml-science-20261026/live-gpi2.json)
does not qualify the new Hsm path. Classic and GPI2 source declarations opt into
tracking for their next deployment. No Hsm live, deadline or hardware claim is
made by these software checks.

## Operational coupled-loop controls

The source extension retains the existing Boolean/plan-generation contract and
startup/hold/resume semantics. Native session admission checks fresh owner
readback before issuing any property effect. Read-only scalar Props publish
Hsm state, fault and accepted desired closure for explicit targets; the existing
Boolean remains applied truth. The provider is FilterGraphPipeWire 0.1.9
(`29428be`, package tree `731b4502efab604f8df1b95e67bbf84cabeb609f`); the
consumer requires PipeWireAO 0.6.19 for public display metadata. Hsm remains
registered 0.3.2. RTC 0.2.13 requires the new adapter minimum. No
instrument-specific handler or scientific gain/limit changes
were introduced. The [design](../../HEADLESS_RTC_DESIGN.md#operational-controls-for-the-existing-coupled-loop)
and [usage](../../JULIA_DEPLOYMENT_USAGE.md#open-and-close-correction) define
the contract and timeout boundary.

Observed CPU software checks on Julia 1.13.2:

- Pure Hsm/status/deadline selector: 237 assertions. Exact deadline, unsigned
  clock wrap, duplicates, gain-only generations, malformed/late observations,
  unavailable observation and read-only PropInfo are covered.
- Graph owner/arguments: 70 assertions, including timeout bounds and explicit
  binding requirements.
- Complete RTC workspace: 4,647 assertions across 166 testsets pass with
  `Pkg.test(; julia_args=["--threads=1"])`. The later deployment-only change
  adding the required helper to the sealed script list passes the affected
  staging selector (42 assertions) and runtime export selector (58 assertions).
- Combined real graph/native-filter callbacks: 46 assertions. Initial status,
  pending/applied distinction, busy rejection, opposite requests, gain updates,
  read-only mixed-write rejection, late adoption and disabled observation pass.
  This selector does not connect to a live daemon.
- Complete graph-adapter CPU coverage: 1,421 assertions across 70 testsets.
  The full-file run passed 69 testsets/1,418 assertions; its last new progressive
  test initially omitted the fixture's mandatory deployment rate. Correcting
  only that test argument yielded the remaining 3 passing assertions in the
  focused selector. All production source was identical between these runs.
  Ordinary, join, progressive, captured rejection, type/collision checks,
  observer failure, thread affinity and processing allocation checks are covered.
  Twenty cold constructor failures with GC disabled retained 18 file descriptors.
- Native real-POD helper, production session admission and existing session
  lifecycle-hook selectors pass using the existing compiled native harness and
  current Lua sources. Denied mixed writes leave gain, closure and generations
  unchanged and do not fault the healthy session. The same production selector
  fails against the original session source because it issues `property-write`.

Independent cross-review found and resolved two partial-publication admission
defects. OP01: a missing state with remaining target fields initially bypassed
the guard. OP02: all target values missing while PropInfo still declared them
also bypassed it. Admission now recognizes target bindings from values or
declarations and requires complete readback. Missing declared global version
also refuses admission. Both fixes have fail-before/pass-after helper and
production-session cases; final review found no remaining actionable finding.
Final integration also found OP03: the sealed staging list omitted the new
helper even though Meson installs it. The list now includes it, and a generic
test scans the actual exported Lua sources for application dependencies. That
test fails before the fix and passes after it; staging current scripts with
the existing compiled RTC also passes. Independent packaging review found no
further omission.

The exact native runner environment is retained in
`operational-native-tests.sh`; the SDK/harness is the existing
`classic-shutdown-20261021/rtc-fixed-build` with its `prefix-fixed` runtime.
The new tests are registered in Meson, but fresh configuration was blocked by
missing SQLite development pkg-config metadata; no C code changed. Some runs
of the unchanged lifecycle selector reached its 8-second harness cutoff during
concurrent CPU work; a separate run passed without changing its wait bounds.
Those cutoff runs do not establish a production lifecycle regression or fix.

Timeout expiration is checked on owner control observations/publication, not by
a background timer. Remote native Props queries can read cached parameters;
polling alone does not force a Julia getter call. No automatic retry/open/reset
or flatten action is added. Native session effect deadlines and required-owner
loss retain their existing fault policy. Generation equality proves plan
adoption, not a transition frame or physical response. Live Classic/GPI2,
scientific calibration and GPU use remain unchanged. No live Hsm, physical,
deadline, tail-latency or independent-corrector qualification is claimed.

The final source is merged to main and pushed as RTC `28ebd5b` / `v0.2.13`
(registered package tree `4e348106888c2d6a724270b2df01cef7e9663fc6`) and adapter
`29428be` / `FilterGraphPipeWire-v0.1.9`. Registry commit `f23faa9` publishes
the consumer's updated dependency floors. A fresh environment from the updated
GPI2 pins resolves those exact releases, PipeWireAO 0.6.19 and Hsm 0.3.2 with
no source overrides. The installed-release combined selector passes the same
46 assertions. Classic and GPI2 use identical pins; the instrument repository
remains local. The instrument offline profile selector passes 49 assertions,
including CPU/CUDA/AMDGPU authoring/export equivalence without loading GPU
packages; both changed Project files pass standalone Taplo checks.
The task's two temporary implementation worktrees were removed
after merging; unrelated worktrees and user edits were preserved.

Read-only service inspection confirms the live GPI2 RTC PID 806596 / invocation
`da8c3efa93eb4a65b4a21998468d4455`, GUI PID 812043 / invocation
`67d5f3c4f2b549eb860b2511ad47153f`, and Classic RTC PID 256761 remain unchanged.
This is source/package integration, not deployment of the new controls.

## State entry/exit and native adoption timers

RTC 0.2.14 uses Hsm `@on_entry` to start the deadline and arm a native one-shot
timer in Opening/Closing. `@on_exit` cancels it on adoption or fault and clears
the pending timestamp. Observer teardown also cancels and closes native sources
before filter destruction, including exceptional shutdown paths. The existing
root `@on_initial` is retained only for initial selection of Unknown, following
Hsm 0.3.2's own flat-machine example and initialized-constructor contract.
Hsm.jl itself is unchanged.

The existing bootstrap ThreadLoop owns the PipeWire `TimerSource` resources.
Its callback only calls public `notify_properties!`; the graph's main/control
thread performs expiry checks and Hsm dispatch during native publication.
There is no Julia Timer on the graph thread, second Hsm writer, new scientific
command or dependency. Early/stale wakes re-arm the remaining original duration
without extending the deadline. Same-Boolean updates do not arm a timer.

Focused CPU evidence on Julia 1.13.2:

- The complete package workspace passes 4,708 assertions across 172 testsets
  through `Pkg.test(; julia_args=["--threads=1"])`, including the new native
  timer selector registered in `test/runtests.jl`.
- Pure state/status/deadline checks: 251 assertions, including direct accepted
  requests proving entry/exit owns the timing independently of Observer callbacks.
- Native timer checks: 30 assertions covering wake-only callbacks on another
  thread, adoption/fault cancellation, early-wake rearming, duplicate bindings,
  pending-owner shutdown, closed handles and idempotent cleanup.
- The optional `test/test_correction_timer_private_core.jl` selector passes
  56 assertions: the previous 46 callback checks plus an isolated private-core
  case that blocks the constructing Julia thread in the native filter loop.
  No frames, later property command or client polling occurs. Logical time
  advances only from the real timer callback; timeout status publishes and the
  actual closed Boolean/active generation remain unchanged. A separate bounded
  watchdog ends a failing run rather than hiding a missing publication.

On the minimum Julia 1.12.7, a fresh resolved test environment passes 351
state/timer/owner-argument assertions across 19 testsets without warnings.
The first 1.12 run used the repository's 1.13-generated manifest: its tests
passed, but precompilation reported a Zstd_jll failure and loaded-stdlib version
notes. The fresh 1.12 environment resolves/precompiles successfully and its
subsequent fresh-process selector is clean; the tracked 1.13 manifest was not
replaced. Logs preserve both attempts.

Independent source review found no blocking defect in Hsm dispatch, source
lifetime, ThreadLoop locking or partial cleanup. Its native rearm-coverage gap
was addressed by the added early-wake test. As with the existing PipeWire timer
API, callback exceptions are retained until a subsequent source update; the
binding therefore requires a nonthrowing wake operation. Production supplies
only native property notification. Native session effect deadlines/owner-loss
fault handling remain in force; this does not claim recovery after a failed
native wake or a hard real-time timer deadline.

No live Classic/GPI2, GUI, calibration, mirror limit or control gain changes
were made. These are CPU software/control-loop integration checks, not physical
actuator, GPU, cadence or tail-latency qualification. No native C code changed.

Publication: RTC commit `a014baf` is merged to main and pushed with tag
`v0.2.14`. Registry commit `c36a6fd` registers tree
`2fa3cf5ffcdf4bf1841025be9c952f4dbb39ec23`. Local instrument commit `de7afc0`
pins Classic and GPI2 to RTC 0.2.14; both Project files pass Taplo checks.
A fresh environment resolved from GPI2's Project installs that registered tree
without a source override, alongside FGPW 0.1.9 and Hsm 0.3.2. Its isolated
private-core selector passes all 56 assertions. The first verification command
attempted to import transitive Hsm directly from the instrument environment;
Julia correctly rejected that import before tests ran. Removing the unnecessary
import fixes the invocation without changing package code or dependencies.
Read-only service inspection confirms the same live RTC/GUI PIDs and invocation
IDs listed above; no running session was restarted.

## Operational definitions and first live Hsm deployment

This follow-up starts from RTC `3163805` in the dedicated
`codex/loop-operations-20261026` worktree. Earlier no-deployment statements
above describe the earlier increments, not this follow-up. The maintained
[operation design](../../HEADLESS_RTC_DESIGN.md#hold-resume-flat-restoration-and-controller-reset)
now separates implemented hold/resume from proposed reference restoration and
controller-only reset. It documents missing scientific rebase/reference
interfaces and prevents history from restoring in-flight effects or bypassing
fresh admission. No new reset/flat command or hierarchical coordinator is added.

The optional CPU `test/test_correction_operations.jl` selector passes 36
assertions on registered FGA 0.8.1: nonzero controller correction and mathematical
state remain held, resume matches the nonunit-pole/anti-windup recurrence,
nonfinite held inputs still reject, reset retains configuration but clears
feedback history, and downstream slew advances under held demand. Independent
review identified that the first draft held zero mathematical state; the final
selector establishes nonzero state before hold. Reset's caller-buffer check is
array-level evidence, not a native actuator-publication claim. Existing
integrator/allocation selectors pass another 138 assertions. The new selector
also passes against installed registered RTC 0.2.16.

The native RTC is rebuilt in an isolated copy of the existing SDK prefix. All
12 native test programs pass. Missing SQLite development metadata was supplied
by extracting the distribution's development package into task-local build
storage. The first link attempts selected an unavailable library or the static
archive; resolving the development symlink to the existing shared SQLite
library repaired the build without source changes. Initial environment
resolution also retained old exact RTC/FGPW manifest selections; targeted Pkg
updates resolve the explicitly pinned releases without editing a Manifest.

Live preparation reuses the existing verified calibration: all 36 FITS files,
the concrete graph, parameter configuration, simulator configuration,
instrument publication, calibration receipt and GUI definition are byte-equal
to the previous live application. The calibration receipt remains
`7506ef36e89d658c4636fd79c3e75e1e3deef27bd675b13500d041cc0df0a86a`.
Only RTC/FGPW and Hsm's required dependency additions change in the initial
registered environment. Classic remains untouched.

The previous GPI2 unit `626bfcad2d04` reproduced its recorded native shutdown
failure during supervised stop. The service retained failure, then confirmed
cleanup and empty owned processes/cgroups; this is not a clean Quit pass.
The first replacement, RTC 0.2.14 unit `09d81ac5861d` / invocation
`3e23849fb8a745eeb1944fdc575b40cf`, failed admission after scientific preparation.
The native run/reset parser rejected newly published correction-status fields
with `Unrecognized reserved node control field`. The later bootstrap-revocation
error is a consequence of that session fault. Failed startup cleanup is
confirmed and its application/session are retained separately.

A new real `owner.node_operation` regression fails before the fix and passes
afterward. Unlike the existing session-hook mock, it exercises mixed scientific,
run and reset Props records through the production parser. Known correction
status, including Unknown/faulted status, does not prevent lifecycle controls;
unknown namespaces and unknown correction fields still reject before writes.
The test cancels after submission, so acknowledgement completion remains a live
gate. Exact run/reset record validation and token/result matching are unchanged.
Independent source review found no blocking issue in that narrow allowlist.
All 12 native programs pass again after the fix.

The fix is `10d969f`, released from the stable loop-control source cohort as
RTC 0.2.16, tag commit `425be43`, registered tree
`1e8e232f2483ae3eec75a0a2e53a8c2c767cc4ad`, registry commit `a355532`.
Main advanced concurrently with separate calibration work; merge `e42adb3`
preserves that work and integrates this fix. The deployment uses the stable
tagged cohort, not those unrelated calibration changes. Local instrument
commit `6a02142` pins Classic/GPI2 to 0.2.16; both Project files pass Taplo.
An incorrect `v0.2.15` tag was published at concurrent main `62864e3` after an
unchecked fast-forward failure. It was not registered and is not a package
release; published history was preserved and the corrected release uses 0.2.16.

The corrected registered application is running as unit `a2fc621d05b7`,
invocation `c77c2507674748b9be622f8d1b0db31b`, native RTC PID 1247025.
The CUDA simulator is PID 1246622 and the ordinary CPU controller PID 1246620.
Before Start, a correction write is refused with `Correction control requires
a running session`; complete property snapshots before/after are equal.
After Start, Open and Close both report active adoption, requested/active
generations 1/1 and 2/2, and exact Open/Closed status, matching desired/applied
Booleans and an empty Hsm fault. Correction is left closed.

Fifteen native streams each deliver 36–39 distinct sequences, including the
242 × 240 UInt16 camera, three demanded and three Applied products, and DM
role/constraint/offset/shape products. Demand-to-Applied Float32 scaling and
same-sequence header comparisons are exact for all three correctors. All owned
temporary observers close. The unchanged GUI binary/layout is relaunched as
PID 1261394, invocation `87cac261d7f4405c8f13c6dd03a71ee8`. Cold startup takes
about twelve minutes on this host; this is not a latency qualification.
Final independent readback confirms Running/Closed, an empty correction fault,
the registered 0.2.16 tree, GUI clients on the exact new remote and absent
software-renderer overrides. Classic retains PID 256761 / invocation
`df8f66d196d54d4c869aa64e6c7f4562`. The installed native policy files match the
registered package byte-for-byte. A first receipt-only invocation accidentally
shadowed `Base.values`; renaming that local binding repaired the read-only
verification script without changing a running process or sending another
actuator update.

Raw logs, source drivers and byte comparisons are retained under
`live-operational/`. These are software and simulated control checks, not
physical-device, settling or deadline qualification. The native shutdown
failure recorded above remains unresolved by this scope.
