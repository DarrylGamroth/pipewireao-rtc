# Native acquisition lifecycle helper review

Date: 2026-10-06. Disposition: no confirmed defect found in the reviewed cold
runtime/client helpers. Source analysis and the bounded tests below support
integration of this transport foundation. Actual acquisition owners, callers,
restoration behavior and installed qualification remain pending.

## Scope and provenance

The reviewed implementation is worker commit `66e991e`, integrated as
`633bfb0ca9617bb7ce4bb1f3ec2e0424d5325527`. This review uses a separate clean
worktree at `2b8271e`:

- Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-lifecycle-helpers-review`.
- Branch: `review/acquisition-lifecycle-helpers-20261006`.
- Only this review document is committed by the reviewer. Investigative code
  and logs are retained in the task cache. Production sources are unchanged.

The [helper contract](NATIVE_ACQUISITION_LIFECYCLE_HELPERS.md),
[integration plan](NATIVE_ACQUISITION_LIFECYCLE_INTEGRATION.md),
[foundation review](NATIVE_ACQUISITION_LIFECYCLE_REVIEW.md), and RTC-DEV-030 govern
scope. NAL-001 through NAL-004 remain accepted integration obligations, not
codec defects. These helpers provide no second acquisition owner or scheduler.

Reviewed production paths:

- `deployment/julia/src/native_acquisition_lifecycle_runtime.jl`:
  construction, atomic wake, poll/take, completion, terminal synchronization,
  and cleanup.
- `deployment/julia/src/native_acquisition_lifecycle_client.jl`:
  exact discovery, fresh Status, Connect and instrument validation.
- Existing `native_control_endpoint.jl` and `native_control_client.jl`:
  controller proof, callback staging, ticket/deadline validation and retirement.
- PipeWireAO 0.6.16 public Registry listener, Core sync and ThreadLoop interfaces.

## Ownership and wake proof

| State | Writers/readers | Publication and lifetime |
| --- | --- | --- |
| `runtime.wake` | Endpoint publisher, Registry listener and Core error callback set true; sole owner poll/take clear it | Julia `Threads.Atomic{Bool}` load has acquire semantics and store has release semantics in Julia 1.12.7; it is a wake hint, not authority for ticket contents |
| Endpoint pending ticket, controller proofs and failure | Callback and serialized owner access under the same ThreadLoop lock | Generic endpoint owns bounded decoded values; poll/take/check revalidate authoritative state under lock |
| Registry listener | Created and retained by Runtime; callback only sets wake | Concrete listener field prevents collection; listener is detached under the owning loop lock before endpoint/Registry destruction |
| Sync acknowledgement | Core callback writes `acknowledged_sequence`; owner reads it under loop lock | Exact returned public sync sequence is compared; an earlier acknowledgement cannot satisfy a later request |
| `runtime.closed` | Sole serialized owner | Idempotent cleanup marker; concurrent close/use is outside this owner contract |

The required service sequence is `has_pending` → `poll!` → `take!`, with no
second wake test between poll and take. Both cold operations clear the hint
before entering the locked generic endpoint.

- A callback that stages work before the clear is followed by authoritative
  inspection under the same loop lock, so clearing its hint does not discard
  the staged work.
- A callback that runs after the inspection sets another wake for the next
  owner boundary.
- An event between poll and take is covered by take's own controller refresh
  and pending-ticket inspection. Asynchronous bound NodeInfo responses publish
  capabilities and set the wake again when they arrive.
- Registry addition/removal wakes discovery even when no request can yet be
  admitted. Changes and retirement of already bound controller proofs also
  call the endpoint publisher, so they do not depend solely on Registry events.
- A taken ticket is now applying; an idle wake is not its deadline monitor.
  The actual owner must continue checking the ticket and its nested deadline
  while applying effects. This is NAL-003, not a new task or hidden timer in the
  runtime.

The retained Registry listener follows the public `ManagedListener` contract:
keep it alive, detach on the owning loop or under its lock. It neither reads
native-private registry storage nor bypasses the generic identity checks.
The extra listener copies Registry announcements through the existing public
API. That cold allocation is outside the no-event idle fast-path measurement.

## Identity, effects and terminal behavior

The runtime delegates admission to the existing endpoint: controller registry
ID, object.serial and controller instance must match a verified live proof;
endpoint incarnation, monotonic token, operation and canonical payload remain
fenced. One request may be pending. Duplicate/collision handling does not
replace another accepted ticket. Take retires expired or removed-controller
requests without returning them for effects. Successful completion checks the
same applying ticket, live controller and remaining deadline again.

The caller waits for Prepared or Connected and then sends a new Status token.
An initial completion sentinel or retained capability is not accepted as fresh
status. Connect requires a successful Connected snapshot. Every returned
completion snapshot is checked against the selected Classic/Copper instrument;
mismatch faults the generic client and throws unknown outcome. The generic
client retains exact profile/PID/incarnation binding, serialized requests and
no retry/reconnect after unknown outcome.

`complete!` encodes the actual owner's result; it does not apply effects,
restore a figure or update the endpoint's advertised lifecycle automatically.
The owner must use `lifecycle!` consistently with the result it publishes. The
fixture does so. Failure results may retain a truthful snapshot or None.

`flush_terminal!` sends public Core sync after publication, observes the exact
acknowledgement under the loop lock, and checks the original absolute deadline
before and after each wait. It does not reset the budget. Actual cleanup must
precede the successful terminal completion; endpoint withdrawal follows the
barrier. A barrier acknowledges daemon processing of the publication, not
scientific restoration or receipt by every other client. A caller resolves
success only from its matching completion; removal before observation remains
unknown under the generic client contract.

Constructor failure attempts listener, endpoint, Core, Context and ThreadLoop
cleanup while preserving primary/cleanup errors. Ordinary close detaches the
listener first, then closes the endpoint and connection resources under the
loop lock, and finally closes the loop. Explicit serialized close remains the
owner's responsibility.

## Evidence

### Existing connected fixture, independently inspected

`/home/dgamroth/.cache/rtc-live-controls-20261005/acquisition-lifecycle-helpers-20261006.log`
records **174/174** codec checks and **74/74** cold connected-helper checks.
The reviewer read both the log and the corresponding fixture source. The worker
ran the following command on CPU 15:

```sh
taskset -c 15 julia --project=deployment/julia -e 'using PipeWireAODeployment; include("deployment/julia/test/test_native_acquisition_lifecycle_codec.jl"); include("deployment/julia/test/native_acquisition_lifecycle_client.jl")'
```

The fixture covers both lifecycle profiles, fresh preparation/status,
profile/instrument mismatch, Connect, report cursor lag, unsupported calibration
Reset, correction window/generation change, queued expiry, controller removal,
terminal synchronization and idempotent cleanup. Its warmed idle atomic load
and the no-wake service path each assert zero Julia heap bytes.

This allocation result excludes startup, Registry events, native/JLL allocation,
callbacks, actual control work, scientific processing, failure paths and cleanup.
It is not an inclusive owner allocation or latency claim.

### Independent boundary discriminator

Evidence root:
`/home/dgamroth/.cache/rtc-lifecycle-helpers-review-20261006/`.
The reviewer ran `discriminator.jl` with `taskset -c 15`, `--startup-file=no` and
the review worktree's `deployment/julia` project. `discriminator.log` records
**16/16 passed** in 7.9 seconds:

1. The runtime reaches no-request idle and retains its public Registry listener
   across a full garbage collection.
2. A later independent public Filter addition and removal each set the wake.
3. After a successful warm sync, SIGSTOP of the owned private daemon makes
   `flush_terminal!` expire under a 150 ms budget; the observed call stays below
   one second. SIGCONT permits a fresh synchronization to complete.
4. Terminating that owned daemon while the runtime is idle sets the wake;
   polling then fails closed with the retained endpoint failure.
5. Listener, endpoint and runtime close successfully after transport loss;
   repeated runtime close succeeds.

The initial investigative script used an unavailable `Base.SIGSTOP` constant.
It reached 11 passing checks and then had a setup error. That log is preserved
as `discriminator-signal-setup-rejected.log`; the rerun uses locally verified
Linux signal numbers 19/18. No production change resulted from that error.

Runtime evidence records Julia 1.12.7, one default Julia thread, default Julia sysimage,
optimization level 2, default bounds policy, startup disabled and affinity CPU15.
The loaded PipeWireAO 0.6.16 source is
`/home/dgamroth/.julia/packages/PipeWireAO/QRGDD/src/PipeWireAO.jl`, with native
artifact `02332925c3953742006b7b962621affb654fc265`. Public listener source was
compared with the inspected local package source and has identical SHA-256.
No hardware, scientific or vendor workload was run.

## Identities and disposition

| Artifact | SHA-256 |
| --- | --- |
| Runtime helper | `d0c91a9864ade6b68ef354b52443c1a3e831932927b8fa4fcf159462cf93e2e6` |
| Client helper | `2d2d26302ef93bf23c0f3afbce16deb698faea152dc63fa5e25db31cca4142d5` |
| Connected fixture | `ef38c8b35f0ce9a7c6d0f57382b516b1ccae74523b76d1aacc9952bb05b84e94` |
| Julia Manifest | `091f8392f1aae31e32a0ff05594d798d8b8694c75a29e6b545056bc674e1f172` |
| Independent discriminator | `0a0c45483fcba5a06222491231ca076a295b782dfbd643c20bcb14c8059e290c` |
| Independent passing log | `eebadf5d0b083dbd0f5ac28af8071cbbb506af5238db80809c06bae18b015a5c` |

No new defect ID is assigned because no confirmed defect was established.
NAL-001 through NAL-004 remain the required checks for actual owner integration:
truthful held/restored state, correction restoration boundaries, safe serialized
cancellation/shutdown and independent live/report cursors. In particular, the
synthetic fixture's Shutdown flags do not prove real restoration.

Acceptance here is limited to cold transport helpers and their scoped idle
fast path. Installed Classic/Copper FGN/JFG/HEART operation, scientific
equivalence, inclusive allocation, and real-time performance remain separate.
