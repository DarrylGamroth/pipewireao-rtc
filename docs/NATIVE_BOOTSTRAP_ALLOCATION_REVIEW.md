# Independent bootstrap allocation review

2026-10-06. Starting RTC revision:
`4cc6ad92eac04d9725f36ee9ee436b33d901596d`. Review worktree:
`/home/dgamroth/workspaces/codex/pipewire/rtc-bootstrap-allocation-review`,
initially clean. No production edits or SCI runs were made. A small private-core
diagnostic used CPU15 and public SDK objects. The primary agent owns admission
and any production remediation.

## Observed failure and what it proves

The primary's fresh installed Classic FGN run produced 512 exact nonzero
commands and stopped cleanly. Its inclusive interval after the fixed 16-frame
prefix, covering 496 subsequent frames, reported **3,862,872 allocated bytes,
73,836 pool allocations, 17 malloc allocations, and zero GC collections**.
This is a failed allocation gate despite functional success and zero observed
collections. No gate scope or warmup adjustment is proposed here.

The primary subsequently ran a diagnostic reset cohort in the same installed
v5 process, retaining the first failure. Both cohorts used the unchanged
16-frame prefix and 496-exchange inclusive interval. Run 1 repeated exactly
3,862,872 bytes / 73,836 pool / 17 malloc; run 2 reported zero bytes, all
allocation counts zero, and zero GC. Both retained matching frame prefix hash
`3564e289278004d7120f044df3c0e1e2dfb3e7a925558e82dd898a7f543c6eca`
and command prefix hash
`b374f9a064080d078d2a157d19105ab58e064b90a789d4c8ec95c83067d30a8f`.
The reviewer inspected these values in
`classic-fgn-v5-repeat-diagnostic.lifecycle.json` in the primary evidence cache.
This discriminates against continuously allocating quiet science/monitor work
for that retained setup. It does not erase the first-cohort failure or isolate
one startup call as the sole cause.

The inspected 2% sampled profile is
`~/.cache/rtc-native-final-deployment-20261006/classic-fgn-v5-sampled-allocations.txt`.
It contains compiler work, native Node construction/removal, capability/Pod
construction and registry copying beneath
`NativeOwnerBootstrapRuntime._poll_ready! → NativeControlEndpoint.poll! →
refresh_controllers!`. Its aggregate call trees do not contain an event timeline
that proves these allocations ended at startup. Inclusive stack totals must not
be added as independent allocation totals or extrapolated into a unique cause.

## BOOT-ALLOC-001 — Registry wakes allocate after compilation is warm

**Severity:** high for the required whole-process allocation gate.
**Confidence:** high. **Evidence:** observed source and independent diagnostic.
**Disposition:** confirmed; primary-agent design/adjudication required. No
production change made.

Affected code:

- `deployment/julia/src/native_owner_bootstrap_runtime.jl`: registry listeners
  set `wake` on every global addition/removal; `_poll_ready!` calls endpoint
  polling when the wake or pending-ticket condition holds.
- `deployment/julia/src/native_control_endpoint.jl`: `refresh_controllers!`
  obtains copied registry snapshots, allocates filtered match vectors, and
  binds new candidate controllers or closes retired ones. `publish!` rebuilds
  capability and parameter values.
- Public SDK `src/core.jl`: `globals`/`find_globals` return copied Globals,
  property dictionaries and a result vector, even when nothing changed.

**Independent measurement:** a public native `Transport`, with no science or
scientific owner task, was created on a fresh private core. Four calls warmed
the concrete measurement path. Two subsequent measurements each reported:

| Operation | Julia allocated bytes |
| --- | ---: |
| Quiet `_poll_ready!` | 0 |
| One forced wake, unchanged registry | 8,384 |
| Public `find_globals` snapshot alone | 8,384 |
| `capability(endpoint)` alone | 13,840 |

The wake test changes only the wake hint; it creates no new controller or
global during the measured call. It therefore distinguishes recurring snapshot
cost from compiler startup and Node binding cost. It does not establish that
every wake in the installed failing run had this cost, or attribute all
3,862,872 bytes to polling. The fixture selects the canonical source SDK
explicitly and reports both loaded module paths.

**Important correction to the initial hypothesis:** refresh does not close and
rebind every live controller on every call. Existing IDs are skipped. It does
copy registry contents and allocate match vectors each time, binds newly seen
controller names, and closes retired controller objects. The sampled close/bind
stacks are consistent with controller churn and first-use compilation, but do
not by themselves establish ongoing rebinding of stable controllers.

The prior BOOT-R001 zero-allocation quiet-monitor result remains valid. Its
scope excludes new ingress. Quiet success cannot establish a process budget
when registry activity or accepted commands occur during science.

## BOOT-ALLOC-002 — Wake filtering alone cannot satisfy arbitrary live ingress

**Classification:** confirmed SDK behavior and derived architectural constraint.
**Confidence:** high. **Disposition:** preserve as a design constraint, not an
instruction to rewrite the protocol or weaken the gate.

Before application wake filtering can run, SDK `_registry_global_added`
constructs a Global, copies its interface string and property dictionary, and
copies property strings. The managed listener's `_listener_registry_global`
constructs another copied Global before invoking `on_global_added`. Thus even
an application callback that ignores an unrelated new global cannot remove
these allocations. `NodeInfo` callback materialization also copies information.

A selected native GUI client exports a controller marker; every subscribed
owner registry can observe it. Ordinary registry-file GUI listing is different:
it is read-only and does not publish such a controller. Arbitrary live native
attachment/selection, registry changes, and commands must not be conflated with
that listing operation.

Additionally, accepted native requests copy their payload into a Ticket and
construct completion/rejection/capability Pods. Those cold control transactions
currently allocate by design. Keeping a connection open avoids repeated
controller creation and destruction, but does not make those transactions
allocation-free inside the owner process.

Consequently, with the current copying SDK registry and endpoint control API,
whole-process zero Julia allocation under arbitrary concurrent GUI attachment
or control is not achievable by changing `_poll_ready!` alone. Moving these
allocations off the science thread does not remove their GC-pressure impact on
the same Julia process. A broader requirement would need an approved bounded
nonallocating public SDK/control design, or a process boundary that preserves
the required owner identity and control authority. Neither is assumed or
implemented in this review. Raw-pointer bypasses, ignoring controller removal,
or dropping required commands are not proposed.

## Minimal discriminating next steps

1. Preserve the original failed cohort, profile, identity, cursor and allocation
   counters. Run the planned diagnostic second cohort on the same retained
   controller after the first control handoff settles. Keep the original
   prefix and inclusive accounting; label this a discriminator, not replacement
   evidence for the failed initial run.
2. Correlate controller/global add/remove and accepted-command counts with
   allocation intervals. A quiet second cohort distinguishes startup/handoff
   activity from a continuously allocating science/monitor path. It cannot
   establish arbitrary-ingress zero allocation. Recurring allocation with no
   events needs a separate profile rather than a speculative ingress rewrite.
3. Inspect lifecycle ordering before changing it. `Deployment.wait_state`
   creates a client and closes it in `finally` when the requested native state
   is observed. The qualifier then creates a second persistent client after
   science has begun. Retaining one exact client and proving its controller
   admission before SCI resume can remove this birth/death handoff. Merely
   returning the temporary client after Running would not prove that all of
   its startup work preceded science.
4. If adjudicated, distinguish registry dirtiness from request/lifecycle wakes
   and use bounded incremental controller bookkeeping through public SDK APIs.
   That can remove unrelated repeated snapshot/bind work. It must preserve
   full NodeInfo identity proof, serial/incarnation tombstones, controller
   removal, Core failure, pending-ticket deadlines and terminal flush. It does
   not solve the SDK materialization constraint in BOOT-ALLOC-002.

No branch should disable pending-ticket checks or terminal processing merely
because science is active. No proposed fix is validated by the diagnostic
fixture alone; the unchanged inclusive installed gate and existing identity,
deadline, removal, lifecycle and quiet-idle suites remain required afterward.

## Retained admission-client remediation review

The primary's candidate adds `wait_state(f::Function, runtime, predicate; ...)`
and runs `f(state, client)` inside the original native client's try/finally.
The original overload returns just the state through this implementation. The
qualifier borrows this client, verifies its live UUID and PID, and performs the
entire cohort before returning. It no longer connects or manually closes a
second controller during that scope. Timeout and live readiness semantics are
unchanged; the callback is not assigned a new 900-second lifetime merely because
that was the initial admission timeout. Each later control retains its own
existing absolute deadline.

An independent real native Preparing supervisor fixture passed **11/11** scope
checks: usable exact-UUID/PID client in the callback, another successful Status
through that same client, preservation of the callback return, closure after
success and after a thrown callback, preservation of the thrown exception, and
the original plain API's state/UUID behavior. No mock transport or SCI was used.
Closure checks inspect the actual client's closed state; one finally close site
and removal of the qualifier's manual close were also reviewed in source.

### BOOT-ALLOC-003 — Cleanup exception could leave qualification successful

**Severity:** high for qualification validity. **Confidence:** high.
**Evidence:** source and actual native failure injection. **Disposition:**
primary accepted; minimal success-assignment/catch correction source-verified.

The first callback candidate set `record["success"] = true` before returning
from the callback. If the owning `wait_state` finally then failed to close the
client, the qualifier catch recorded the exception without clearing success.
`qualification_exit_code` accepted that inconsistent record after otherwise
successful service cleanup. This exception became part of the outer try through
the new callback scope.

The diagnostic deliberately set the borrowed native client's active flag just
before callback return, making its actual close method refuse an active
operation. It restored the flag and closed the client during diagnostic
cleanup. The resulting record contained the native ArgumentError, successful
service-cleanup facts and `success=true`; the candidate reducer returned zero.
This injects an error branch, not an allegation that the normal serial cohort
has an active request at close.

The primary moved success assignment after `wait_state` returns and explicitly
sets success false in the catch. This preserves close failures as qualification
failures. A defensive reducer check for any recorded failure is also planned.
The separate first-cohort installed allocation replay is owned by the primary;
the native scope fixture alone does not validate the allocation repair.

## Diagnostic evidence

The small fixture and its unedited output are retained under
`docs/validation/bootstrap-allocation-20261006/`. It loads source SDK through
`LOAD_PATH`, then the producer deployment project, starts only a private core
and native control Transport, and closes both. Its explicit allocation checks
and private-core liveness assertion passed. Julia compiled the deployment
package before measurement; the log retains that warning/provenance. This is
a warmed method-level allocation diagnostic, not an installed SCI replay or
a claim of zero native-library heap use.
