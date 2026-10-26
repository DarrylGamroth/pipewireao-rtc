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
