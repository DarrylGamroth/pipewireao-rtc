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
