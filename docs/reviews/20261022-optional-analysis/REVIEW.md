# Optional CPU analysis isolation review — 2026-10-22

The revised design plausibly preserves the required control path: WFS summary
science runs in a separate Julia process behind capacity-one copy/drop-oldest
queues, and its output reaches the generic GUI through another such queue.
Confirmed lifecycle, identity, and startup defects found during implementation
were remediated. Independent software checks and reviewed primary-agent live
receipts support those repairs: five finite CPU generations completed with exact
controller replay despite optional suspension, termination, and preparation
failure. This establishes the tested functional isolation, not a cadence or
tail-latency guarantee.

## Scope and source identity

Independent review of RTC lifecycle, optional SDK links, acquisition matching,
row-major transport, and the Classic application declarations. The reviewer
changed only this document and used temporary CPU-only verification scripts.
No live service was started/stopped, no GPU was used, and nothing was pushed.

| Worktree | Branch | Starting revision |
| --- | --- | --- |
| `pipewireao-rtc-analysis` | `codex/optional-wfs-analysis-20261022` | `5b53296deede43ff0d1aa7d6bfaf8ccb1ae4bcc8` |
| `JuliaFilterGraph-analysis` | `codex/acquisition-synchronization-20261022` | `12e894941e76cb69a97e56694daf01b0740b0115` |
| `revolt-classic-rtc-analysis` | `codex/optional-analysis-20261022` | `7989bcf8e0f521cf288b50a45902ef32a44d2a06` |

All three worktrees already contained implementation changes when review began.
The JFG remediation reviewed and tested is commit
`5a8dc2fdb0f5ae58e7f7dc3b108448ea2a1d1b48`. Final RTC source inspection is at
commit `aa6ca4f9c9a9d797060683572bf14c0f0e73413e`, package tree
`0289467179b49448e4323354a496896b858a38bb`; the Classic application HEAD is
`d81e3de9bfe6a3bf2d9ccc1604d55fd97f0aef96`. The CPU fault gate used the earlier
immutable RTC tree explicitly identified under OA-007, with an independently
checked single runtime delta. The evidence hashes below identify the actual
gate harness and application Manifest.

Primary-agent raw live receipts referenced by filename below are under
`/home/dgamroth/workspaces/codex/worktrees/optional-wfs-analysis-20261022`.

Authorities: RTC `AGENTS.md`, `RTC-ARCH-026`, `RTC-DEV-006`, and the task's
explicit optional-process boundary. The low-latency design review skill was
used to inspect capacity, ownership, overload, scheduling, and recovery.

## Ownership and bounded work

```text
required JFG WFS outputs (slopes, flux, validity)
  → three existing server queues, capacity 1, copy/drop-oldest
  → optional CPU JFG process, one copied sample slot per input
  → coherent acquisition join → WFS summary Algorithm
  → separate server summary queue, capacity 1, copy/drop-oldest
  → ordinary GUI ndarray consumer
```

The RTC retains required owners, admission, run control, and required links.
Analysis is submitted only after a fresh native Ready/Running identity check.
Its service is outside the required cohort and owns its ordinary non-lingering
SDK `link-factory` proxies. Analysis failure has no reverse Requires/BindsTo
dependency on the RTC. systemd owns process lifetime; PartOf/Requisite express
the one-way relationship. Optional After ordering was removed as described in
OA-007. Optional receipts and fragments are separate
from required-owner records, with a bounded lifecycle lock around optional
submission and cleanup.

Configuration bounds are eight analysis services and 64 links per service.
Analysis inputs require declared capacity-one copy/drop-oldest queue playback;
outputs require an exclusive observation capture without required playback
consumers. Analysis uses ordinary scheduling, Nice=10, RestrictRealtime=yes,
LimitRTPRIO=0, two Julia default threads, single-thread BLAS, and hidden GPU
devices. The selected CPUs 6/7 are physical core 3 on the inspected host and do
not share a physical core with the declared required-process CPUs. CPU and
memory interference elsewhere in the machine remains measurable, not excluded
by these settings.

The strict join pins domain identity for its lifetime, admits only increasing
generations, resets science once on a new generation, and matches sequence and
Header PTS. Missing identity/PTS and incoherent windows do not publish. An
incomplete window is replaced by a newer arrival; no unbounded backlog or wait
is introduced. Producer-domain replacement closes admission until a new owner
is prepared. Ordinary `:sequence` matching retains its prior API behavior.

## Findings and disposition

### OA-001 — Optional cleanup proof could strand required consumers

- Severity: P1. Confidence: high. Evidence: observed in a deterministic source
  execution with a fake manager; source-derived for actual systemd behavior.
- Affected code: RTC `src/deployment/session_launch.jl`, `cleanup_record!`;
  `src/analysis.jl`, `verify_cleanup!` and `cleanup!`.
- Original mechanism: optional receipt/fragment validation ran after core and
  source revocation but before required consumer teardown. A malformed receipt
  or changed optional fragment threw and prevented the required Julia owner
  from being stopped. Optional bookkeeping therefore gated required cleanup.
- Remediation: required sweeps exclude separately optional analysis roles,
  complete required consumer and fragment cleanup, then perform independently
  fenced optional cleanup. A role actually listed in required owners remains
  required even if its spelling starts with `analysis-`.
- Verification: the actual `cleanup_record!` expression was evaluated with a
  deterministic fake manager and an optional cleanup exception. The resulting
  order was core, simulator, Julia, required fragments, optional failure. With
  the original verification placement restored, the same oracle stopped only
  core and simulator. Four assertions passed. A durable two-assertion regression
  was subsequently added to `test/test_analysis.jl` and independently passed.
  No systemd was contacted.
- Disposition: remediated and independently verified for ordering. The final
  primary-agent fault gate also completed all three session cleanups. An
  optional identity failure may still retain optional resources and a
  failed-cleanup diagnostic; it no
  longer prevents verified required-owner teardown. Final source inspection
  also confirms that missing optional receipts cannot silently hide leftover
  optional units/jobs: cleanup reports their presence without stopping an
  identity it cannot prove. That diagnostic edge was inspected but was not
  covered by the initial 93-assertion run.

### OA-002 — Explicit strict-join reset reopened old sequences

- Severity: P2. Confidence: high. Evidence: source and passing regression tests.
- Affected code: JFG `julia/JuliaFilterGraph/src/synchronized_inputs.jl`,
  `reset!` and `_reset_synchronized_sequence!`.
- Original mechanism: reset cleared the sequence watermark while preserving
  domain/generation. A subsequent older sample from that retained generation
  could be admitted, contradicting the lifetime acquisition fence.
- Remediation: matching-mode dispatch preserves the completed watermark for
  acquisition matching and retires an active window at its sequence. Default
  sequence matching still clears its history on reset.
- Verification: independent focused core tests include reset after both a
  completed and an incomplete acquisition window, newer-generation reset,
  old-generation/backward-sequence rejection, and permanent domain rejection.
- Disposition: remediated and independently verified at JFG commit
  `5a8dc2fdb0f5ae58e7f7dc3b108448ea2a1d1b48`.

### OA-003 — Optional summary capture retained required-loop placement

- Severity: P2. Confidence: high for placement; timing impact was not measured.
- Affected code: Classic `core.conf.in`, summary queue `capture.props`.
- Original mechanism: after summary science moved out of the controller, the
  queue capture still selected `rtc-data-loop`, placing optional summary
  transport work on the required processing loop.
- Remediation: summary capture and playback both select `observer-loop`.
- Disposition: remediated by application configuration and independently
  inspected. The retained live `fault-final3/analysis-ready.json` exposes
  `node.loop.name=observer-loop` on both summary queue nodes. This verifies
  published placement properties; it does not measure callback scheduling time.

### OA-004 — Endpoint identity needed checking around link creation

- Classification: accepted defensive improvement with an explicit residual
  API limitation, not an experimentally observed misconnection.
- Evidence/confidence: high source confidence. RTC `ext/analysis.jl` originally
  checked stored serials only after readiness. The standard factory resolves
  current global IDs, which are reusable; a local thread-loop lock does not
  freeze the server's global registry.
- Remediation: confirm the analysis endpoint is this process's published node,
  recheck node/port serials before each creation and after negotiation, and
  validate all four LinkInfo endpoint IDs before declaring readiness. Continue
  checking endpoint presence/serials, link presence, and graph state afterward.
- Disposition: improvements inspected. Serial validation and factory creation
  are not one atomic server operation. The supported topology assumes sealed
  server queue modules remain unchanged for an RTC invocation; manual removal
  and recreation of those nodes is outside that contract. A core restart closes
  the private remote. Do not claim arbitrary manual global-ID replacement is
  atomically fenced by the SDK creation call.

### OA-005 — Canonical systemd CPU ranges rejected the optional service

- Severity: P2. Confidence: high. Evidence: primary-agent live receipt reviewed
  independently, plus source inspection and focused regression execution.
- Affected code: RTC `src/deployment/systemd_unit_files.jl`, `verify_fragment!`
  and `_unit_cpus`; `src/deployment/systemd_owners.jl`, Placement import.
- Observed: immutable candidate tree
  `1c31e4d0316d2e0e09d21bb13b53cd97ea6e8ef4` reached RTC Ready but rejected the
  optional service policy. `integration-candidate.log` records
  `loaded optional analysis resource policy differs` before optional submission.
- Mechanism: the unit renders `CPUAffinity=6 7`, while the manager reports its
  equivalent set as `6-7`. Literal string comparison rejects valid affinity.
- Remediation: parse the reported whitespace/range CPU list using the existing
  Placement parser, sort/deduplicate it, and compare the numerical CPU set.
  Realtime, Nice, lifetime, fragment, and other resource checks remain active.
- Verification: independently reran `test/test_analysis.jl`: 97 assertions
  pass. These include `6-7`, `6 7`, mixed ranges/single CPUs, and a complete
  fake-manager fragment with `CPUAffinity=6-7`; disabling RestrictRealtime still
  fails verification.
- Disposition: remediated and independently verified at software level. The
  completed final live gate reached analysis Ready; its CPU audit reports all
  eight observed analysis threads on `6-7` with ordinary scheduler policy 0.

### OA-006 — Readiness printing waited for the native owner loop to return

- Severity: P2. Confidence: high for the reproduced mechanism and its scoped
  repair, supported by independent reproduction and the completed live gate.
- Affected code: RTC `ext/analysis.jl`, readiness notice in
  `analysis_connections` and its replacement `analysis_ready_notice`.
- Observed: candidate tree `689ce2e39db397b4ad2c1b167d37bf30a8cc253a` published
  four links but its integration readiness check timed out. The retained
  `integration-candidate2.log` reports 16 passing assertions and one error.
  The primary agent observed the readiness journal line only when SIGTERM
  released the native main loop; this reviewer did not operate that session.
- Derived mechanism, independently reproduced: Julia pipe `println`/`flush`
  from another Julia thread depends on main-thread libuv progress. In a local
  two-thread test, thread 1 stayed in a GC-safe 700 ms native call, while thread
  2 attempted output after 100 ms. The Julia output operation took 602.9 ms and
  remained unfinished when the native call returned. The equivalent POSIX
  write completed on thread 2 in 0.0139 ms before that return. These numbers
  discriminate the blocked dependency; they are not performance qualification.
- The primary agent's separate `readiness-io-probe.json` records direct output
  at 0.32 s and Julia output at 3.22 s, together with main-thread return. Its
  result agrees with the independent probe.
- Rejected hypothesis: callback `Core.Box` aliasing was initially proposed.
  Lowered code from the actual immutable candidate has boxes for context/core/
  registry ownership, but no boxed link-state binding. A faithful reproducer
  retaining the later assignment inside its original `while` scope updates
  `[3, 0, 0, 0]` correctly. The misleading `[0, 0, 0, 3]` reproducer moved that
  assignment to function scope and changed the semantics. Seven independent
  assertions reject that hypothesis. `analysis_link_observer` remains useful
  defensive clarity and passes 11 independent callback/endpoint checks, but it
  is not evidence of a repaired production closure defect.
- Remediation: emit the single bounded startup line through POSIX fd 1 with a
  GC-safe native call, retain the message, and require an exact-length write. This
  is a Linux/systemd deployment diagnostic outside the science callback; it
  removes the Julia pipe/libuv dependency. It does not promise that an arbitrary
  blocked stdout consumer can never impose backpressure.
- Disposition: readiness-notice helper source inspected; three independent
  checks confirm the actual helper finishes on thread 2 while the main thread
  remains in native code, with no GPU packages loaded.
  The completed final isolated gate reached analysis Ready and passed the
  subsequent fault/replay checks described below. Remediated within that scope.

An additional proposed timeout defect was rejected after checking the caller:
`run_analysis_graph` wraps `analysis_connections` in a monitor `try/finally`
that calls `quit!`. A test of only the inner function omitted this existing
cleanup obligation and did not establish a production leak.

### OA-007 — Optional stop ordering delays direct RTC control revocation

- Severity: P1. Confidence: high for the ordering defect, derived from source
  and official semantics and supported by the primary agent's real-manager
  fail-before/pass-after receipt. The reviewer operated no services.
- Affected code: `src/analysis.jl`, the `after=[session_unit]` argument;
  `assets/deployment/pipewireao-session@.service.in`, RTC ExecStop;
  `src/deployment/session_runtime.jl`, distinct `shutdown!` and `stop!` paths.
- Mechanism: PartOf propagates the RTC stop to analysis. After reverses their
  shutdown order, so analysis must finish stopping before RTC stop processing,
  including its control-revoking ExecStop, can begin. An unresponsive optional
  process therefore introduces its stop timeout into required shutdown.
  [Official unit ordering documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#Before=).
- Correction to the proposed scenario: SIGSTOP alone does not imply the full
  15-second timeout; systemd also sends SIGCONT during termination. Slow or
  signal-resistant termination still exposes the ordering defect.
  [Official kill procedure](https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html#KillSignal=).
- Minimal remedy: remove only the optional service's After argument. Retain
  Requisite and PartOf, exact native Ready/active-incarnation validation,
  lifecycle locking, and independently fenced cleanup. Requisite does not start
  the RTC or add ordering; PartOf retains stop propagation. The generic service
  renderer and required-owner ordering should remain unchanged.
- Verification boundary: native `shutdown!` sends Quit before manager cleanup;
  that gate cannot establish prompt control revocation for direct `systemctl
  stop` or `SessionRuntime.stop!`. Check generated optional units have no RTC
  After/Before edge, and separately test direct stop with deliberately slow
  optional termination in an isolated session.
- Disposition: remediated. Independent final source inspection confirms only
  the optional service loses its After argument; generic renderer ordering
  remains available. The focused 97-assertion suite passes, including absence
  of optional After/Before edges. Reviewed `ordering-final.log` reports six
  passes for two exclusive dummy service pairs. In the retained
  `ordering-final/ordering-result.json`, required stop follows optional
  completion by about 52 ms before repair, and precedes optional completion by
  about 1.004 s after repair. The optional stop script deliberately waits one
  second. This proves manager ordering, not RTC science or a timing guarantee.
  The reviewer read `ordering.jl`: it invokes the actual `service_unit`
  renderer, changes only the After dependency, waits for the optional completion
  marker and manager quiescence, and removes both pairs' units/fragments.
- Source scope: the completed `fault-final3` science gate uses RTC
  tree `fc59c6c6a1c60ae816ada147476b7c4c012aa15a`, which still has the old
  After argument. Its `ext/analysis.jl` matches the reviewed final source; its
  `src/analysis.jl` differs solely by OA-007's argument removal and explanation.
  Keep that bounded delta explicit. The dummy-manager gate supports the new
  ordering, but the science gate must not be described as executing the final
  source revision of that unit declaration.

## Primary live evidence independently reviewed

The reviewer read the completed `fault-final3/optional-analysis-result.json`,
the actual `harness-final3/classic_optional_analysis.jl`, phase observations,
both full summary identity records, all three final launch receipts, resource
audits, and `integration-final3.log`. These services were operated by the primary
agent; the reviewer did not rerun or control them. The log records 2,999 + 473 +
472 = **3,944 passing assertions**, with no failure. The retained earlier failed
candidates remain evidence of the repaired startup problems; they are not
superseded with a claim that all development runs passed.

| Phase | Generation | Captured control frames | Verified replay |
| --- | --- | --- | --- |
| Analysis running | 1 | 32 | Exact controller and detector |
| Analysis suspended during the run | 2 | 32 | Exact controller and detector |
| Analysis resumed | 3 | 32 | Exact controller and detector |
| Analysis killed during the run, separate session | 1 | 32 | Exact controller |
| Analysis preparation failed, separate session | 1 | 32 | Exact controller |

Every observed control stream has 32 distinct sequences, from 1 through 32,
with the expected generation and domain `a0000000000000000000000000000000`.
Normal/resumed records additionally retain all six streams, including summary:
their complete 32-element identity and PTS arrays match, and every sequence is
present. The harness checks the eight summary fields against their source
samples. Controller replay compares current and pre-summary baseline outputs
bitwise and compares them with captured outputs. All 320 reported warmed
controller calls allocate zero bytes. This is a replay allocation observation,
not an allocation claim for every live process or callback.

The configured offered wall rate is 2 Hz, with 32 finite exchanges per
generation. The science configuration's nominal rate does not turn this into a
500 Hz runtime qualification. The normal/stalled/resumed capture-and-replay
durations are approximately 46.39/25.13/20.39 seconds and include replay work;
they are not transport latency distributions. Suspension/termination is
scheduled asynchronously three seconds after Start so observation continues
during fault injection. Stop and status remain usable, resets advance the main
session generations, and native Quit performs teardown, including teardown
while analysis is suspended. Direct manager stop ordering is separately covered
by OA-007's six-assertion experiment.

All three `final-launch.json` files report `phase=stopped`,
`service_result=success`, `cleanup_complete=true`, `unit_files_removed=true`,
and no error. Their invocation identities are
`0071ee40bc6143869f806f679291ba19`, `f3f7369d60e34f48bd6f5accf084813d`, and
`b30228ed4569452e908df2efba011307`. The reviewer also read each invocation's
separate runtime `analysis.json`: all report cleanup complete with an empty
error list. Their durable copies, `retained-analysis.json` in each of the three
fault-stage directories, were subsequently inspected and agree. Retained owner
PID/state entries are historical launch identity,
not a fresh process-state query. The harness independently checks that the
analysis MainPID is zero after each cleanup.

The main-session analysis audit records eight threads, all ordinary policy 0
on CPUs 6/7; its harness checks the analysis process for GPU-library mappings.
The separate required-process GPU audit records no such mappings. The summary
queue exposes observer-loop placement on both ends. These are snapshots for
this CPU gate, not a general hardware-resource or GPU qualification.

The report's harness SHA-256
`e304684bf55ad8d9f739cea11a1d0f6ae0b29a9b894a927d40fae722df0f40b6` and Manifest
SHA-256 `110e6096e4ab626c2f4192338a358de14b650338f3144c0791af2f36c8064f05`
match the retained files. Independent `git diff` of the fault-gate and final RTC
trees confirms that the only runtime change under `src/`, `ext/`, and `assets/`
is removal of the optional After argument plus explanatory comments, matching
`final-runtime-delta.json`. Final-source `offline-final.log` records 74 passes;
`analysis-policy-final.log` records 97 passes. Those two are primary runs; the
reviewer's separate focused executions are recorded below.

### Final installed CPU application and GUI subscriptions

The reviewer inspected the primary agent's read-only live checks under
`/home/dgamroth/.local/state/pipewireao/classic-cpu-analysis-live-20261022`,
their `check_live.jl` implementation, and `check-live.log` in the evidence root.
Both application and installed Manifests select PipeWireAORTC 0.2.5, tree
`0289467179b49448e4323354a496896b858a38bb`; `live-identity.json` records Classic
commit `d81e3de9bfe6a3bf2d9ccc1604d55fd97f0aef96`. This is a final-tree live
observation, distinct from the earlier fault gate and its bounded source delta.

`live-wfs-check.json` reports 32 samples in each of detector, slopes, flux,
validity, and summary, with **31 shared identity/PTS cohorts** and bitwise-exact
summary values against the numerical oracle. The observation receipt explains
the overlap: the detector spans sequences 603–634, while the other streams span
602–633, all in generation 1 of the same acquisition domain. The checker
compares every shared cohort's PTS and eight summary fields; it does not claim
32 complete five-stream cohorts. Saved status responses show Running both
before and after observation. This deployment has an offered wall rate of
10 Hz and nominal model rate of 500 Hz; no cadence claim follows from this
short observation.

`live-analysis-policy.json` confirms the final optional unit is active, outside
the required owners, with Nice=10, RestrictRealtime=yes, LimitRTPRIO=0, and
CPUAffinity=6-7. Requisite and PartOf name the RTC, while its After list omits
the RTC and the RTC's Requires/Wants lists omit analysis. The retained graph
has exactly four active links touching the unique analysis node. Thus the live
loaded policy agrees with the reviewed one-way dependency and ordering repair.

The GUI has one active summary subscription and one active slopes subscription;
detector, flux, and validity have zero recorded GUI subscriptions. The checker
explicitly allows this subset (`all_readout_views_required=false`). This
supports those two active bindings, not a claim that all views were displayed
or manually inspected. `live-gpu-audit.json` records no matching GPU-library
mappings or GPU device handles for all seven observed roles: core, RTC, Julia
controller, parameters, simulator, analysis, and GUI. It is a CPU-only process
snapshot. No services were operated during this independent receipt review,
and no new blocking finding was identified.

## Independent verification

Julia 1.13.2 on local Linux x86-64. GPU visibility was disabled. Core/adapter
scripts also assert that neither CUDA nor AMDGPU was loaded. The tests use
`/home/dgamroth/.local/share/classic-review-20261020/depot` and single-thread
OpenBLAS; focused JFG tests use one Julia thread.

| Check | Result | Scope |
| --- | --- | --- |
| RTC `test/test_analysis.jl` | 97 assertions passed | Configuration bounds, queue isolation declarations, ordinary service policy and canonical CPU affinity, fragment fencing, lock deadline/release, required cleanup despite optional failure |
| RTC `test/analysis_links.jl` | 13 assertions passed | Independent callbacks, endpoint mismatch rejection, actual pipe readiness while native owner thread blocks, no GPU modules loaded |
| Real-manager optional ordering receipt | 6 assertions passed, primary run independently reviewed | Two dummy service pairs; before/after direct stop ordering, no science/GPU |
| Faithful callback/source-lowering investigation | 7 assertions passed | Rejected the incorrect production closure-boxing hypothesis |
| Actual readiness-notice helper under native main-thread wait | 3 assertions passed | Linux CPU-only output progress independent of Julia libuv |
| Temporary OA-001 source-order oracle | 4 assertions passed | Fail-before/pass-after teardown ordering with deterministic fake manager |
| JFG focused core selector | 220 assertions passed | Availability, latest/hold, synchronized windows, strict identity/generation/PTS/reset behavior |
| JFG strict warmed allocation report | All 17 paths: 0 bytes | Complete, partial, duplicate, generation, stale, rewind, mismatch, missing, discontinuity, corrupt and domain-change arrivals |
| JFG focused adapter selector | 782 assertions passed | Row-major boundary, synchronized callback publication, adjacent CPU/borrowed-array contracts; no GPU packages loaded |
| RTC working diff whitespace | Passed | `git diff --check` |

Executed commands, with the environment described above:

```sh
julia --startup-file=no --project=. test/test_analysis.jl
julia --startup-file=no --project=/home/dgamroth/workspaces/codex/worktrees/optional-wfs-analysis-20261022/closure test/analysis_links.jl
julia --startup-file=no /tmp/optional-analysis-cleanup-review.jl
julia --startup-file=no --project=/tmp/acquisition-sync-20261022 /tmp/acquisition-sync-20261022/focused.jl
julia --startup-file=no --project=/tmp/acquisition-sync-20261022 /tmp/acquisition-sync-20261022/adapter-focused.jl
julia --startup-file=no --threads=2,0 /tmp/optional-analysis-stdout-review.jl julia
julia --startup-file=no --threads=2,0 /tmp/optional-analysis-stdout-review.jl native
julia --startup-file=no --project=/home/dgamroth/workspaces/codex/worktrees/optional-wfs-analysis-20261022/closure /tmp/optional-analysis-callback-review.jl
julia --startup-file=no --threads=2,0 --project=/home/dgamroth/workspaces/codex/worktrees/optional-wfs-analysis-20261022/closure /tmp/optional-analysis-ready-review.jl
```

The temporary selectors execute repository tests; the scripts are local review
helpers, not new production entrypoints. The core selector includes
`conditional_availability.jl`, `latest_hold.jl`, and `synchronized_inputs.jl`. The adapter
selector includes the synchronized-input, queued-arrival, supported-publication,
acquisition row-major boundary, and multidimensional borrowed-array testsets
from `julia/FilterGraphPipeWire/test/runtests.jl`.

## Remaining validation and claim limits

The completed primary-agent CPU gate supports finite functional equivalence
with analysis running, suspended, resumed, killed, and unable to prepare.
Baseline equivalence is established by exact local replay, not by a separate
live session with the feature removed. The final unit-ordering delta has its
own real-manager before/after experiment; the science gate did not execute that
final declaration. GUI stall/reattach, arbitrary systemd activation races,
production-rate overload, latency distributions, deadline/tail guarantees, and
hardware actuation remain unqualified here. No live services were operated by
the reviewer. Functional/allocation evidence must not be promoted into an
unmeasured scheduling guarantee.

This first service requires a graph with at least two synchronized data inputs
and a single acquisition domain. Future analysis graphs must declare their own
input-join contract and resource budget. The architecture permits additional
processes, but this review does not qualify arbitrary compositions.
