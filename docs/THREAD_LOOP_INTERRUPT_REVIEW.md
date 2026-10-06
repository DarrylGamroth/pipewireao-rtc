# Native thread-loop interrupt safety: independent review

Date: 2026-10-06. SDK source inspected at
`6e4e1eebf8bd160f01a532dcfc7284dec92de61b` in the clean canonical
`PipeWireAO.jl` worktree. Primary remediation is reserved to
`PipeWireAO-bootstrap-state`, branch `fix/thread-loop-interrupt-scope-20261006`.
This artifact lives in the separate RTC review worktree, initially at `017b6c5`;
it records integration evidence and SDK review, not new SDK architecture
authority. No production edit, test execution, build or SCI by this reviewer.

## Observed installed failure

`~/.cache/rtc-native-final-deployment-20261006/`
`gui-hil-service-classic-fgn-control-allocation-v1/` retains the diagnostic
cohort that omits temporary native selection and repeats midrun controls in
both generations. Both 512-frame cohorts report **zero bytes, all allocation
counts zero and zero GC** in the unchanged 496-exchange inclusive intervals.
The result remains failed because the owned service exits with status 1.
The deployment log records a finalizer and explicit cleanup failure:

```text
InvalidStateException: cannot close a PipeWire thread loop while its native lock is in use
```

The service properties are `Result=exit-code`, `ExecMainCode=1`,
`ExecMainStatus=1`. These observations establish an outstanding SDK native-access
reservation at close; they do not alone establish where the reservation leaked
or whether the native mutex itself was still held.

## SDK-INT-R001 — SIGINT can cross native ownership outside cleanup protection

**Severity:** high for resource correctness and owned shutdown. **Confidence:**
high for the source window; actual signal mechanism requires the discriminator
below. **Classification:** observed source; installed root-cause hypothesis.
**Affected:** SDK `src/thread_loop.jl:112`, `with_thread_loop_lock`.

The method increments `native_access_count` under the Julia state lock, then
performs a GC-safe `pw_thread_loop_lock` before entering its try/finally.
An interrupt delivered after reservation or on return from that native acquire
can therefore escape without native unlock/counter decrement. The current
finally also unlocks before decrementing the counter, leaving another signal
boundary between those actions. Count alone cannot distinguish the two cases.

**Proposed remediation reviewed:** protect the complete reservation, GC-safe
acquisition, callback, unlock and counter-finally scope with
`Base.disable_sigint`. Keep the existing GC-safe native acquire; disabling
asynchronous SIGINT is not disabling GC. Explicit exceptions from the callback
must still execute cleanup. Preserve nesting, return values, public signature,
closed-state checks and zero allocation after exact-method warmup. No raw-pointer
API or new native-lock ownership model is needed.

**Semantic consequence:** asynchronous SIGINT is deferred until the callback
and ownership cleanup finish. The critical callback should remain bounded; this
does not create a new timeout for an arbitrary blocking callback. Do not
automatically reenable SIGINT inside arbitrary native callbacks merely to avoid
deferral. If a future API chooses interruptible callback execution, that is a
separate explicit contract and must retain protected acquisition/cleanup.

Local Julia 1.12.7 `base/c.jl` documents this purpose for `disable_sigint`,
implements balanced sigatomic begin/end, and notes exception-unwind restoration.
Its `reenable_sigint` is a separate operation. Native-lock acquisition's existing
GC-safe behavior must remain, because a native holder callback can request GC
while the Julia caller waits for that mutex.

## Required discriminator and regression checks

1. Fresh disposable Julia child with two threads, `exit_on_sigint(false)` and
   warmed paths. A non-main holder thread acquires the public SDK loop lock;
   the main Julia thread attempts it and becomes blocked in native acquisition.
2. Parent sends exactly one SIGINT only after the child proves main thread 1,
   distinct holder thread and reservation count two while the holder still
   owns the lock. Keep holder execution on the same OS thread: use a sticky task
   or non-yielding GC-safe native sleep, avoiding migration of a task owning a
   pthread recursive mutex.
3. Release the holder after a finite delay. Require the expected interrupt to
   be observed, then zero reservation count, successful native reacquisition
   by a **different OS thread**, and normal close. Main-thread recursive
   reacquisition alone could hide a leaked native mutex.
4. Retain the unchanged fail-before/pass-after oracle and source identities.
   Bound the child externally and signal only the owned child. Count-zero and
   independent native reacquisition are distinct proof obligations.
5. Recheck nested/recursive use, callback return/exception behavior, fresh use
   after interruption, the existing warmed 1,000-lock zero-byte test and native
   callback GC-participation lock/stop children.

**Initial disposition:** the proposed full interrupt-protected ownership scope
is architecturally coherent. No production patch is accepted as a demonstrated
fix until the focused signal oracle and relevant allocation/GC checks pass.
Historical installed failure remains a hypothesis about signal timing until
correlated evidence distinguishes it; even a reproduced SDK defect does not
retroactively prove the exact interrupt location in that service run.
