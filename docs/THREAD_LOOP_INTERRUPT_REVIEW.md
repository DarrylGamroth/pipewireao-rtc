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

## Cold ownership proof and allocation discriminator

Independent follow-up reviewed the primary's dirty SDK worktree at baseline
`6e4e1ee`, before production helper extraction. The unchanged child oracle fails
before (2 pass / 3 fail, `interrupted=true count=1`) and passes with the complete
`disable_sigint` scope (5/5, `count=0`, closed and cross-thread reacquired).
The actual holder is a native loop callback, whose native mutex ownership does
not reserve the SDK counter: the correct waiting witness is **one** SDK
reservation, not the two-reservation arrangement proposed above. Its callback
uses GC-safe native sleep and does not migrate while holding the mutex. The
parent sends one signal only after the reservation/holder witness, and bounds
the owned child. Independent source inspection and retained child output support
the ownership conclusion. Existing lock allocation checks pass 6/6, and both
GC-participation children report completion for lock and stop.

### SDK-INT-R002 — initial protected closure regresses prepared publication

**Severity:** high against the existing zero-allocation contract.
**Confidence/classification:** confirmed by unchanged cold native fixture.
**Affected:** initial `with_thread_loop_lock` interrupt patch and its prepared
parameter publication callers. **Disposition:** initial closure form rejected;
minimal helper candidate independently passes the original fixture, pending
the primary's complete ownership/GC suite on the resulting production source.

Canonical source passes all 17 private-core prepared-publication assertions.
The initial protected closure passes 12 and fails all five allocation checks:
16/32/48/64/48 bytes for empty/single/four/mixed/repeated prepared sets. Retained
allocation profiles identify `PreparedParams{N}` objects, **not `Core.Box`**.
PreparedParams remains concretely typed; calling this a type-inference failure
or blaming its immutable GC root is not established.

Independent CPU15 diagnostics used Julia 1.12.7, the existing SDK environments
and actual disposable private-core fixture. No SCI, build, production edit or
new dependency was involved. Results:

| Temporary variant | Result | Interpretation |
| --- | --- | --- |
| Canonical / initial protected closure | 17/17 / 12/17 | Independent reproduction |
| `@noinline` protected method | 12/17 | Restoring the outer call boundary alone is insufficient |
| Preserve extracted params/pointers owners | 12/17 | Does not justify changing parameter storage/preservation |
| Flat sigatomic begin/end around identical body | 17/17 | Structural discriminator; not the chosen API |
| `disable_sigint` calls normal protected-body helper | **17/17 unchanged fixture** | Small candidate retaining supported wrapper and ownership scope |

The candidate extracts reservation, GC-safe acquire, callback, native unlock
and reservation decrement into one ordinary internal helper. The public method
invokes that helper from `Base.disable_sigint`; no arbitrary inline annotation,
parameter representation change, pointer API or interrupt-policy relaxation is
needed. The helper must remain internal and called only within that protected
scope. The primary owns production implementation and final verification.

**Reflection limit:** LLVM shows canonical `publish_batch` calling the lock
method while the initial patch inlines the signal wrapper and calls its inner
closure. However a temporary fixture that asks `code_llvm` to compile the single
parameter specialization *before measurement* changes the helper candidate's
result to one 32-byte failure for that inspected specialization. The unchanged
fixture passes all 17. Reflection output is evidence about that compiled method,
not proof that an ordinary caller retains identical optimization. The extracted
owner and noinline experiments do not establish the exact compiler root cause.

Scripts, logs, representative IR and SHA-256 receipt are retained under
[`validation/thread-loop-review-20261006`](validation/thread-loop-review-20261006/receipt.json).
The exact helper acceptance command was:

```text
taskset -c 15 julia --startup-file=no --project=/home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state /tmp/review-loop-helper-exact.jl
```

The retained script temporarily redefines the methods in a fresh process and
includes the original `test/native_control_private_core.jl` by absolute path.
Final acceptance still requires the selected production helper to pass the
signal child, explicit/nested callback exceptions, zero-byte lock/publication
checks, GC lock/stop children and full relevant SDK suite. Installed clean-stop
and whole-process SCI evidence remain separate gates.

## Final selected-source verification

The primary selected the normal helper with public `Base.disable_sigint`.
Independent final review used the SDK's uncommitted patch above `6e4e1ee`, with
RTC integration reference `32e55e7`. The production helper matches the tested
candidate after normalizing its name, comments and whitespace. Its only call
site is inside the public method's interrupt-protected scope. The diff changes
only this ownership implementation/documentation and its regression tests;
public arguments, callback results, native handles and prepared parameter
representation remain unchanged.

Reservation is made under the state lock while SIGINT is deferred. The outer
finally decrements that reservation; the nested finally unlocks only after the
native acquire returns. Explicit callback errors traverse both cleanups.
Nested use retains recursive native locking and balanced counter increments.
Pending asynchronous SIGINT is delivered after the protected scope releases
ownership. Acquisition remains GC-safe. No additional ownership race was found
in this bounded source review. Bounded callback execution is still required;
this repair does not make an arbitrary blocking callback cancellable.

Independent CPU15 execution against the selected production method passed
**15/15**: ten lock-allocation/return/nested-error checks and five actual SIGINT
ownership checks. Process exit was zero. The retained witness is
`reserved=1 holder_thread=4`; the child reports `interrupted=true count=0
main_thread=1`, successful cross-thread reacquisition and closed ownership.
The primary's full-suite log independently counts **2,032/2,032 assertions in
63 sets**, including 17 prepared-publication checks and four GC-participation
checks, with final package-test success and no failure markers. Separate final
GC lock and stop child logs both report completion. The full-suite log retains
a stale-manifest dependency/compat warning; this review did not resolve or
change dependencies. The displayed test environment selects this SDK worktree.

Final source hashes, full-suite log, independent parent/child output and witness
are recorded in the [final receipt](validation/thread-loop-review-20261006/final/receipt.json).
The independent execution used:

```text
PIPEWIREAO_INTERRUPT_EVIDENCE=/tmp/rtc-sdk-final-independent-20261006 taskset -c 15 julia --startup-file=no --threads=2,0 --project=/home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state -e 'using PipeWireAO, Test; include("test/thread_loop_allocations.jl"); include("test/thread_loop_interrupt.jl")'
```

**Disposition:** SDK-INT-R001 and SDK-INT-R002 are resolved for the reviewed
cold SDK source and measured fixtures. This reviewer made no production edit
and ran no SCI. Installed replay remains required; the exact interruption
location in the historical service shutdown failure remains unproven.

## Installed replay after the SDK repair

The primary repeated the `control-allocation` user-service scenario with SDK
main `d514d6b`, unchanged runner `750059d1…d5cb`, CUDA AOS and CPU Classic FGN.
The fresh installed descriptor is `885fbe6e…dcacb`; all 579 seals verify. The
refresh preserves every scientific artifact and every other SDK file; only
`hil/packages/PipeWireAO/src/thread_loop.jl` changes in the staged SDK.

Both cohorts complete exactly 512 frames and commands. Both measured
496-exchange intervals have zero heap allocations and GC activity, including
the midrun controls. Stopped reset preserves the identical frame/command
prefix and truth. The service exits normally with status zero and confirmed
owned cleanup, invocation `fa1779aebb7843f18f2928751cd57e99`.
The [service receipt](validation/thread-loop-review-20261006/service/receipt.json)
retains reports, the preparation recipe, source identities and hashes of the
compressed recordings preserved in the cache. The earlier failed result and
its owned cleanup proof remain retained.

This passes the previously failed installed shutdown reproducer. It does not
pinpoint the historical interrupt location. The scenario deliberately omits
the temporary selection client and reports `gui_qualification=false`; neither
arbitrary GUI attachment nor the full receiver matrix is qualified here.
The log retains precompilation/version warnings and the private-core missing
D-Bus support warning. This is functional/allocation evidence, not an isolated
cadence or latency measurement.
