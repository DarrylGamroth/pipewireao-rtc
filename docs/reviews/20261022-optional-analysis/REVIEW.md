# Optional CPU analysis isolation review — 2026-10-22

The revised design plausibly preserves the required control path: WFS summary
science runs in a separate Julia process behind capacity-one copy/drop-oldest
queues, and its output reaches the generic GUI through another such queue.
Confirmed lifecycle, identity, and startup defects found during implementation
were remediated. Software checks and a scoped real-manager ordering experiment
support those repairs. End-to-end fault isolation and control-loop scheduling
remain limited to the completed evidence explicitly recorded below.

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
`5a8dc2fdb0f5ae58e7f7dc3b108448ea2a1d1b48`; RTC and application evidence below
refers to the contemporaneous working changes, not their untouched starting
commits. Final publication must identify the resulting RTC/application commits.

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
- Disposition: remediated and independently verified for ordering. Live manager
  fault/cleanup behavior remains a separate gate. An optional identity failure
  may still retain optional resources and a failed-cleanup diagnostic; it no
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
  inspected. Runtime loop placement remains to be checked in a live gate.

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
  later candidate reached published analysis links, independently supporting
  resolution of the earlier submission failure. Final live gate remains open.

### OA-006 — Readiness printing waited for the native owner loop to return

- Severity: P2. Confidence: high for the reproduced mechanism; the final live
  remedy must still pass the isolated integration gate.
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
  The final isolated live gate must demonstrate analysis Ready and subsequent
  fault/replay behavior before the end-to-end defect is declared closed.

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
- Source scope: the concurrently running `fault-final3` science gate uses RTC
  tree `fc59c6c6a1c60ae816ada147476b7c4c012aa15a`, which still has the old
  After argument. Its `ext/analysis.jl` matches the reviewed final source; its
  `src/analysis.jl` differs solely by OA-007's argument removal and explanation.
  Keep that bounded delta explicit. The dummy-manager gate supports the new
  ordering, but the science gate must not be described as executing the final
  source revision of that unit declaration.

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

No live RTC/control-loop equivalence experiment, analysis SIGSTOP/SIGKILL test,
GUI stall/reattach test, systemd activation race, shutdown fault injection, or
cadence/tail-latency measurement was performed by this reviewer. Acceptance of
runtime isolation still requires identical finite control inputs with analysis
absent, running, stalled, crashed, and GUI stalled/disconnected, comparing
accepted commands and acquisition identities while observing RTC lifecycle.
Verify installed unit policy, physical CPU affinity, actual loop placement,
ordinary scheduling, and exact cleanup in that same isolated private session.
Record offered rate, duration, sample counts, drops, and latency distributions;
functional/allocation checks alone do not establish a deadline guarantee.

This first service requires a graph with at least two synchronized data inputs
and a single acquisition domain. Future analysis graphs must declare their own
input-join contract and resource budget. The architecture permits additional
processes, but this review does not qualify arbitrary compositions.
