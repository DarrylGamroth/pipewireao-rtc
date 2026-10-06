# Native ordinary-owner bootstrap review

Review date: 2026-10-06. Reviewed revision:
`491e040d1832b2b89abffd0ae751ae8a06866576`; implementation comparison starts at
`40f86a3`. The source branch was `work/native-control-planes-20261005`, clean at
inspection. Independent review worktree:
`/home/dgamroth/workspaces/codex/pipewire/rtc-bootstrap-review`, detached at the
reviewed revision and initially clean. Production files were not changed by
this review. Investigative scripts and logs are retained under
`~/.cache/rtc-native-owner-bootstrap-review-20261006/`.

## Scope and decision

The native bootstrap preserves the intended thread ownership and exact native
identity boundary in the inspected paths. **The reviewed revision is not ready
for the inclusive simulator allocation gate:** BOOT-R001 confirms continuous
allocation by the idle bootstrap monitor. Installed scientific, allocation,
thread placement and systemd evidence remain separate required gates being
performed by the primary agent.

Authority is [RTC-ARCH-024](architecture.md#native-live-control-transport),
[RTC-DEV-030](operations.md#rtc-dev-030--native-local-live-controls), the approved
[bootstrap design](NATIVE_OWNER_BOOTSTRAP_DESIGN.md), and the existing
[allocation contract](LIVE_CONTROL_ALLOCATION_PLAN.md). Moving work to another
task in the simulator process does not exclude it from that allocation gate.
Preparation, intentional cold bootstrap transactions, stopped reset and final
serialization remain distinct from quiet connected operation.

## Ownership and bounds inspected

| Boundary | Observed source behavior | Assessment |
| --- | --- | --- |
| Native ingress | `NativeControlEndpoint` owns one pending ticket, retained terminal reply and independent rejection under its ThreadLoop lock; verifies actual controller metadata and registry incarnation. | Preserves accepted request against competing or malformed requests. |
| Supervisor binding | `NativeOwnerBootstrapClient` binds absolute private remote, exact node, spawned PID and positive incarnation, then issues fresh Status. Deployment retains the client. | Cleanup does not reconnect or use saved reports/markers as authority. |
| Main and monitor | Main constructs on Julia default thread 1; ThreadPinning starts a sticky monitor on default thread 2. Atomic cancellation and a handshake lock protect shared facts. | Node construction, Connect, run and closure remain on the constructing thread. |
| JFG stop | Monitor invokes the public any-thread quit hook under the handshake lock; main removes hooks before closing the node. Quit is repeated until main excludes hooks. | Covers the race between requesting quit and main entering native run. |
| Accepted effects | Main and monitor check the retained receipt-based ticket deadline and controller; late effects cannot produce successful expired completion. | Failure cancellation and finite supervisor process revocation remain necessary for a blocked native call. |
| Terminal result | Main publishes finished only after its closure/report work returns; monitor publishes terminal state/completion and synchronizes before endpoint closure. | Saved reports are artifacts; bootstrap success does not derive from report presence. |
| Scientific loop | Ordinary source checks atomic cancellation at its serialized frame boundary; bootstrap does not execute science from a callback. | Direct warmed cancellation read measured zero allocation. |
| Configuration and exports | Runtime defaults to strict native descriptor validation; legacy input acceptance is an explicit offline exporter option. Exported source and JFG wrappers use distinct bootstrap identities. | Historical marker input is converted before runtime admission. |
| Scientific body seal | Moved `simulator_owner.jl` is included in exported helper hashes and matching exporter/owner frozen helper sets. | Entry-point hash alone is not treated as the moved scientific body seal. |
| Placement | Export descriptors require `rtc-bootstrap` on the leader CPU under SCHED_OTHER; existing JFG pin arguments and row-worker assignments are retained. | Descriptor intent is not measured placement evidence; installed validation must identify Julia monitor thread 2 as well as native ThreadLoop. |

No additional confirmed lifetime, deadline, identity, legacy fallback or
scientific body sealing defect was established by this source pass. This is
not proof of untested interleavings or hardware timing.

## BOOT-R001 — Idle monitor violates inclusive allocation contract

- **Severity:** high.
- **Confidence:** high.
- **Evidence class:** observed allocation; derived contradiction of the
  inclusive quiet simulator allocation contract.
- **Affected code:** `deployment/julia/src/native_owner_bootstrap_runtime.jl`,
  `serve!` (line 402 onwards at reviewed revision), and the generic endpoint
  calls it makes; `deployment/julia/src/native_control_endpoint.jl`,
  `refresh_controllers!`, `poll!` and `take!`.
- **Disposition:** confirmed; sent to the primary agent for remediation.
  No production fix is included in this review artifact.

`serve!` calls `Endpoint.poll!` every 5 ms, including Connected with no incoming
control traffic. With no accepted ticket it also calls `take!`. Both traverse
the registry through `refresh_controllers!`; the implementation obtains and
filters allocated vectors. Although the transport already stores an atomic
`wake` hint, the loop does not use that hint to suppress idle registry work.
The cold monitor therefore introduces continual allocation and potential GC
interference in the simulator process.

The focused actual private-core fixture creates a bootstrap runtime, connects
an exact native controller, completes Connect on main and leaves both sides
quiet. Two warmed 500 ms windows use a GC-safe `usleep` on main and process-wide
`Base.gc_num()` / `Base.GC_Diff`. GC remains enabled. The same measurement is
warmed and run before constructing the bootstrap. No SCI frame, source
control, report output or bootstrap request occurs within the measured windows.

| Measurement | Allocated bytes | Pool allocations |
| --- | ---: | ---: |
| Same-process baseline before bootstrap, 500 ms | 0 | 0 |
| Quiet Connected, first warmed 500 ms | 1,753,920 | 14,940 |
| Quiet Connected, second warmed 500 ms | 1,753,920 | 14,940 |
| One warmed direct `Endpoint.poll!` | 9,728 | Not separately measured |
| One warmed atomic `Runtime.cancelled` read | 0 | Not separately measured |

The direct call measurements hold the handshake lock to exclude monitor duty
cycles. The full-process windows do not hold that lock. The observed quiet
allocation rate is approximately 3.51 MB/s on this fixture; this is an
allocation characterization, not an execution-time or realtime claim.

Command (CPU 13, coordinated with the primary agent; no duplicate build target):

```sh
taskset -c 13 julia --startup-file=no --threads=2,0 --project=deployment/julia \
  /home/dgamroth/.cache/rtc-native-owner-bootstrap-review-20261006/idle_allocations.jl
```

Retained script: `idle_allocations.jl`; complete output: `idle-before.log` in
the evidence directory above. The run exited zero. The script includes two
assertions for the observed Connected state/positive allocations and the
private-core helper verifies its daemon remains alive before bounded cleanup.

### Proposed remediation and required validation

Use a race-safe ingress wake signal to avoid registry traversal when Connected
and quiet. Keep main-fact transitions and active-ticket progress/deadline
checks responsive independently of that signal. Audit all request,
controller-proof change/removal and core failure callbacks as wake producers.
Do not clear a newer wake after processing an older event, and do not introduce
a missed-wake window between examining accepted state and sleeping. Accepted
Connect/Quit must still detect expiry and controller loss when no further
request arrives. Cleanup/terminal synchronization must preserve current finite
budgets and must never turn an expired effect into a successful reply.

Repeat the same warmed actual fixture and require zero bytes in quiet
Connected windows with GC enabled. Add a focused quiet monitor regression;
retain actual-core freshness, competing/expired request neutrality, accepted
controller removal, accepted-effect timeout, Fault query and cleanup-before-Quit
checks. Run the installed inclusive scientific allocation cohort after the fix;
quiet transport evidence alone cannot qualify scientific execution or controls.

## Evidence reviewed and remaining gates

The reviewed [bootstrap design evidence](NATIVE_OWNER_BOOTSTRAP_DESIGN.md)
records 47 actual private-core checks, seven actual external JFG checks,
codec/parser/owner suites and 449 exporter checks. The
[deployment validation](NATIVE_DEPLOYMENT_BOOTSTRAP_VALIDATION.md) records
40 strict schema checks, 432 coordination regressions and 59 actual launcher
checks. These are producer-reported evidence inspected alongside source;
this review independently executed only the allocation discriminator above.

These fixtures submit zero SCI frames. Required remaining evidence includes
fresh installed Classic/Copper ordinary and external graph science, inclusive
allocation with midrun controls, actual main/monitor/native-loop placement,
bounded blocked-preparation process fallback, and selected foreground/systemd
operation. No physical device, hard deadline, wall-clock rate or hardware
qualification is claimed.
