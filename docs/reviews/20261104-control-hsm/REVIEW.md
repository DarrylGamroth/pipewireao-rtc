# Control HSMs and Active Objects — 2026-11-04

Status: implemented; software, private-core and scoped allocation checks pass.

## Scope and baseline

This follows the [acquisition and preparation migration](../20261104-calibration-hsm/REVIEW.md)
on `codex/package-cleanup-20261104`, based at
`4658e7f676c538df01c919b4902c9df25a63a105` in `pipewireao-rtc-cleanup`.
The original checkout and prior authorized uncommitted cleanup were preserved.
The four remaining cold candidates from the
[correction review](../20261104-correction-hsm/REVIEW.md#other-state-machine-candidates)
are calibration endpoint action admission, shared control-ticket admission,
bootstrap monitoring and systemd service bookkeeping.

The user also selected Active Objects instead of shared application state and
offered Agent.jl. Local Agent 0.4.1 provides the duty-cycle/runner/invoker
abstractions; its documented scope excludes queues. The registered dependency
was added through Julia Pkg with `PRESERVE_ALL`, retaining existing dependency
versions. Agent's sibling source checkout was inspected without modification.

Authority remains RTC-ARCH-024/026 and the affected RTC-DEV-029/030 contracts.
There is no new session authority or supervisor. systemd retains process lifetime
and the filter/scientific graph remains in its separate process. This is cold
control work; no hard deadline or whole-system GC guarantee follows from Hsm or
Agent usage.

## Ownership and handlers

| Component | Event owner | State-dependent behavior |
| --- | --- | --- |
| Calibration acquisition | One calling control task | Acquiring/Recovery/Terminal handlers; owned batches delivered between dispatch steps |
| Calibration preparation | One calling control task | Active and Terminal parents; immutable confirmation admission |
| Calibration endpoint protocol | One serving control task | Typed action/result events, shared Restore admission and exact run/serial correlation |
| Shared native ingress | Existing PipeWire loop lock serializes native callbacks and owner tasks | Idle/Staged/Applying, terminal publication and closed admission |
| Bootstrap monitor | Reserved Julia thread 2 | Preparation, pending Connect/Quit, owner failure and bounded cleanup |
| systemd service client | One calling control task | Launching/Running/Stopped/Uncertain/StopFailed client bookkeeping |

The shared native ingress retains one pending ticket, one last completed request
for canonical replay, and at most 32 controller proofs. `terminal_request` records
ordinary completed requests as well as terminal ones; it is not a lifecycle
phase. Read-only `applying` and `terminal` properties project the Hsm state.
Resource closure and transport failure remain resource facts, rather than a
second representation of ticket-admission state.

Scientific endpoint `run`, `serial` and `phase` reads project its Protocol Hsm.
Requested handlers dispatch on typed `Actions.Command` parameters. Validation
and run/serial admission precede the existing native retention/effect sequence;
the scientific effect executes outside dispatch and the native loop lock.
Unknown effects still fence and close the endpoint without retry.

Service migration includes the existing Launching state found in maintained
callers. Those callers now use `launching!`, `running!` and `uncertain!` rather
than assigning a stored phase. Identity retention, exact invocation/PID/start
ticks/cgroup verification, stop refusal and uncertainty preserve their previous
order. These are synchronous one-shot clients; they do not need another agent
or mailbox merely to use Hsm consistently.

## Active Object boundary

Run-to-completion requires one dispatcher; it does not itself serialize two
calling threads. The bootstrap monitor is the existing owner suitable for an
Active Object. Owner-to-monitor messages and replies must be typed and bounded;
readers consume immutable published status rather than mutate handshake fields.
Hook exclusion must be acknowledged before science closes its resources.

The native loop lock remains required for native publication, exact-ticket
validation and resource lifetime. A mailbox cannot interrupt thread 1 while it
is blocked in native `run!`; the monitor retains the explicit thread-safe native
quit capability until science excludes hooks. No callback may block on mailbox
space, and no requester may wait for an actor reply while holding a native lock.

AgentInvoker supplies the duty-cycle integration inside the existing reserved
loop, retaining its Hsm failure, cleanup and terminal-release policy. Agent's
runner remains available; this path already has its thread and shutdown owner.

Normal and cleanup channels each hold four messages, with at most four from
each drained per cycle and cleanup visited first. This supports the finite
owner handshake without allowing normal traffic to occupy cleanup capacity.
There is one monitor consumer; multiple owner tasks on thread 1 may send, so
the queues use Channel synchronization rather than an SPSC assumption. Reply
channels each hold one typed result. Check-and-enqueue is one Channel-lock
transaction. Normal full/closed queues reject before acceptance; cleanup waits
for reserved capacity before acceptance. Accepted mutations are never retried.
No callback producer or public owner call waits while holding a native lock.
Channel shutdown wakes senders and queued reply readers.

The monitor owns mutable preparation, connection, failure and hook facts.
Its Runtime proxy publishes Status with release ordering and readers acquire
one immutable snapshot. Quiet health/cancellation reads do not enqueue work.
`finishing!` waits for hook exclusion acknowledgement, which latches a fence
against later connection registration. `cancel!` requests cooperative native
wake without claiming scientific cleanup. These control messages and replies
allocate; they are outside the measured quiet and frame-processing regions.

## Clocks and deterministic time

Registered Clocks 0.4.0 supplies monotonic system and cached clock providers.
It was added through Pkg with existing versions preserved. SystemNanoClock uses
the same underlying `time_ns()` source as the previous elapsed-time helpers;
epoch/reference timestamps and controller-instance entropy remain separate.

Common clock adapters preserve the existing API units:

| Input | Calibration/control deadlines | Correction elapsed arithmetic |
| --- | --- | --- |
| `Clocks.AbstractNanoClock` | Convert nanosecond ticks to Float64 seconds | Read nanosecond ticks before existing validation |
| Existing callable | Preserve its seconds return value | Preserve its nanosecond return value |

Only SystemNanoClock restores the old unsigned system-tick representation for
wrap-safe correction arithmetic. Cached-clock negative or regressing values
remain visible to the consuming validation. Public absolute deadlines and native
wire formats are unchanged. The acquisition driver preserves its separate
pre-exchange deadline rebasing and post-exchange receipt-time capture.

The bootstrap agent owns a CachedNanoClock and samples its injected source once
at the start of a duty cycle. All monitor time decisions in that cycle use the
cache. Its cleanup interval now anchors at that cycle's sampled time. Native
ingress records its own receipt times, and I/O helper loops keep their existing
deadline boundaries; there is no globally frozen native clock. Tests advance
CachedNanoClock explicitly; clock advancement does not deliver a timer event.

## Findings and disposition

### HSM-CTRL-01 — Two transitions in terminal completion

Confirmed migration regression; fixed. Hsm 0.3.2 rejects a second transition
using the original Applying handler after it has already moved to
TerminalApplying. The actual native terminal selector reproduced
`Transition source Applying is not active below current state TerminalApplying`.

`complete!` now dispatches Completed and CompletionReady in one native-lock
transaction. The first event validates and closes terminal admission before
publication. The second publishes and only then retires the pending ticket.
Each handler takes at most one transition. Publication failure retains the
applying ticket and, for terminal completion, the closed gate. Tests cover
acceptance, expiry, nonterminal and terminal publication failures. Independent
review found no remaining ingress finding after the fix.

### HSM-CTRL-02 — Idle failure bypasses bootstrap cleanup

Confirmed migration regression; fixed. Moving `_idle!` outside the monitor's
exception boundary let idle/yield failure bypass first-failure recording,
cancellation and cleanup, and inserted an extra idle before cleanup. Independent
review identified the change; idle was restored inside that boundary. The
monitor loop dispatches observations/events rather than select lifecycle phases.

### HSM-AO-01 — Queued registration can undo hook-exclusion acknowledgement

Confirmed draft defect; fixed and covered by regression tests. Giving cleanup
priority allowed HooksExcluded to acknowledge before an already queued ordinary
registration message. Without a permanent fence, that message could reinstall
hooks after science was allowed to close. The monitor now latches `finishing`
and rejects subsequent connection work before any hook or ticket mutation.

### HSM-AO-02 — Channel binding uses a wrapper instead of the running Task

Confirmed startup defect; fixed. ThreadPinning returns a StableTask, while
`bind(Channel, task)` accepts a Task. An actual private-core startup reproduced
the MethodError. Both channels now bind to `current_task()` inside the monitor's
serve function. Final basic and controller-sealing gates pass.

### HSM-AO-03 — Connected snapshot survives a fault publication

Confirmed draft defect; fixed. Native lifecycle changes initially updated only
the wire projection, leaving readers a stale Connected status. Owner-error and
lifecycle handlers now republish the immutable snapshot so Fault/Stopped and
first failure are visible with the same acquire/release contract. Independent
review checked all three Active Object fixes and reported no remaining blocking
source findings.

### HSM-AO-04 — First-use RPC compilation consumes an accepted deadline

Confirmed cold-start defect; fixed without changing the deadline. An initial
accepted-loss test failed and its cleanup masked the primary exception. The
diagnostic test now retains the primary failure. Paired fresh-process runs with
the same 0.5-second request budget distinguished compilation from transport loss:
cold registration began with 0.4868 seconds remaining, took 0.5907 seconds and
failed the native deadline check. Precompiling the exact concrete message route
before admission took 0.4540 seconds; subsequent registration took 0.1144 seconds
and the complete 51-assertion selector passed. These are diagnostic timings,
rather than latency qualification.

The constructor now precompiles the finite set of concrete owner-message routes
on thread 1 before spawning the monitor and starting its existing five-second
startup wait. Abstract queue storage no longer hides first-use RPC routes from
warmup. Compilation constructs no second Monitor and dispatches no events;
all mutable application state and effects remain owned by thread 2.
The fixed fresh-process run passes 51 assertions: registration starts with
0.4812 seconds remaining, takes 0.1375 seconds and leaves 0.3437 seconds.
The final bootstrap source SHA-256 is
`9ce0b4571ed58f95a49963c92247f38def44912b6604a821f8717c68b6369a2f`.
Independent final review verified all eleven routes, startup ordering and paired
receipts against that hash and reported no remaining finding.

## Verification

Julia 1.13.3 core suite: **9,317 assertions across 415 testsets**, exit 0:

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO; ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir); include("test/runtests.jl")'
```

This process loaded bootstrap before the constructor-only precompilation fix.
The final source's affected startup and private-core gates were rerun afterward;
the Hsm/clock behavior under core tests did not change. The intentional missing
Git object test emits its existing `cat-file` diagnostic; all assertions pass.

Milestone evidence before the Active Object extension:

- Scientific endpoint: 297 offline action/phase/correlation assertions and 47
  actual private-core assertions, including failure and Release delivery.
- Shared ingress: 50 actual two-controller assertions plus 23 client assertions;
  fault selector passes 28 publication assertions plus 8 controller-proof and
  23 client assertions.
- Service client: 116 scripted systemd/identity assertions; session-runtime,
  stop and analysis selectors bring the focused total to 291. No real services
  were manipulated.
- Bootstrap Hsm: 155 offline entrypoint/monitor/codec assertions and 176 private
  core assertions across basic, sealed, idle, terminal and churn selectors.
  Baseline selectors pass the same private counts. Quiet/churn measurements
  report zero allocation and zero GC within their declared measured windows.
- Clocks integration: 1,362 assertions across eight focused selectors, including
  53 new checks for actual cached-clock advancement, exact deadlines, negative
  ticks, regression fencing and preserved callable/unsigned-wrap behavior. Warmed
  clock read/conversion allocation checks pass at zero bytes.

Final Active Object evidence:

- 82 new offline assertions cover facts (24), bounded/reserved messages (14),
  hook exclusion/native capabilities (15), close/failure handling (11) and
  one source-clock sample per duty cycle (18). Existing entrypoint and codec
  selectors contribute 49 and 67 passing assertions.
- Actual private-core gates pass **178 assertions** on the final source: basic
  (51), sealed-controller (66), idle (12), terminal (40) and churn (9). Both 500 ms
  quiet Connected windows report zero bytes/pool allocations; direct
  poll/cancel/preparation checks allocate zero. The measured churn window reports
  zero bytes, pool allocations, mallocs and GC, with confirmed child cleanup.
- The final scalar Hsm allocation selector passes 13 assertions: 1,000 correction
  loop cycles, recovery cycles and ready-preparation checks each allocate zero
  bytes after warmup. This does not measure control-message allocations.

The private selectors use `--threads=2,0` and explicitly select the compatible
artifact prefix. For example, run the core command above with those thread flags
and replace its include path with `test/native_owner_bootstrap.jl`. The other
selectors are `native_owner_bootstrap_sealed.jl`, `native_owner_bootstrap_idle.jl`,
`native_owner_terminal.jl` and `native_owner_bootstrap_churn.jl` under `test/`.

Eight changed Markdown files parse with Julia Markdown; changed link targets
and anchors, fences, final newlines and migrated API help were checked.
`git diff --check` passes. No requirement identities or Mermaid diagrams changed.
The optional external-pupil science selector was not rerun; its cleanup injection
now calls the public cancellation message instead of writing an atomic field.

Existing Hsm scalar evidence remains separate from native startup, failure,
transport and scientific allocations. An Active Object does not isolate GC
between threads of one Julia process or establish an RT deadline by itself.

No installed RTC, shared live core, device or instrument source is changed.
Private-core tests own and close their daemons. Scientific, hardware and strict
RT qualification remain separate. Callback state/slot markers and durable crash
receipts retain the exceptions described in the correction review; adopting Hsm
must not turn those records into a second lifecycle authority.
