# Native HEART wrapper process validation

## Scope

RTC issue #5, RTC-DEV-028 and RTC-DEV-030. The explicit integration fixture
[uses the production wrapper](../deployment/julia/test/native_heart_vendor.jl)
on a private PipeWireAO core with the existing unchanged `scaoTemplate` and
`scaoTemplateCmdClient` binaries. It does not publish WFS pixels or qualify
scientific equivalence, simulation cadence, allocations or physical hardware.

The parent runs on CPU12; the wrapper starts on CPU3 and verifies the existing
vendor worker declaration on CPUs3/4/6/8/10/14. CPU0 is excluded. Scientific
cohorts are stopped during this process qualification. Each wrapper gets its
actual spawned PID, a fresh endpoint incarnation and private remote. Startup
retains vendor INIT/RUN/ENABLE_HRT_FLAGS/CORRECT acknowledgements, ingress and
placement checks. Flag acknowledgement remains weaker than effective readback.

## Observed results

Julia1.12.7: Classic and Copper each passed **60 checks** (26 lifecycle/caller,
34 failure/cleanup). The production Shutdown path stops/reaps the child,
publishes a typed Stopped snapshot and flushes that publication through public
core synchronization before endpoint removal. The client received the matching
terminal result in both runs; this does not guarantee receipt after transport
loss. The source-side `HILHeartControl` caller independently binds the wrapper
and resets it, advancing generation again.

| Case | Required observation |
| --- | --- |
| Preparation/connection | Fresh Ready status and Connect acknowledge the actual live child, placement and immutable generation report |
| Reset | Old child exits; new PID and next generation; old health snapshot rejected |
| Simulator caller reset | Shared HIL client resets the same wrapper using its own admitted controller identity |
| Shutdown | Matching Stopped/nonalive result, recorded exit code, wrapper exits0, all owned children absent |
| Failed preparation | Task-selected `/bin/false` child cannot become Ready; native failure/removal and wrapper exit1 before scientific publication |
| Failed restart | Removal of only the task-owned rendered configuration prevents replacement readiness; old child is fenced and owner faults/exits1 |
| Child exit | Vendor TCP SHUTDOWN outside the wrapper lifecycle ends the child; wrapper publishes failure/removes endpoint and exits1 |

No package configuration, calibration inputs or vendor source were changed.
Failure injection is confined to test-owned runtime state or test argv. Cleanup
uses the wrapper's reserved owned process group and cached actual wrapper PID.

## Evidence

Evidence roots under `$HOME/.cache/rtc-live-controls-20261005/`:

- `heart-vendor-classic-qualified-20261006/` and its adjacent `.log`;
- `heart-vendor-copper-qualified-20261006/` and its adjacent `.log`.

Each root has generation reports, bounded command/process logs and summaries
with actual endpoint/PID identities and SHA-256 of the executable, client,
configuration, maps, placement and requirements. Failure subdirectories retain
their separate summaries and saved native runtime reports.

The unchanged vendor executable SHA-256 is
`1c0862686dc79d127033845a12d32a0d12ac4ccc24a28396f69d0233b16ef9d1`;
TCP client SHA-256 is
`6fe43dbe3fe46155ad36c7d38eac0190eac34c64ac96fddc9905411b04923734`.
The fixture reads immutable previous CPU package inputs; it executes current
wrapper/client code, not the old package's lifecycle controls.

An initial expanded Classic run passed26+33 checks and failed one test
expectation: the test required UnknownOutcome, while the client had already
observed native Fault and correctly returned a preparation failure. The final
fixture accepts the two explicit failure classes (known failure or unknown
transport outcome). Production behavior was unchanged for that correction.
The failed run remains `heart-vendor-classic-full-20261006.log`.

[The independent review](NATIVE_HEART_REVIEW.md) also confirmed NH-003:
calling `getpid` on a reaped child broke both production report and snapshot.
`heart-exited-pid-before.log` records both ESRCH failures; the actual PID is now
retained at spawn, and `heart-exited-pid-after.log` passes31 portable checks,
including six terminal report/snapshot checks.

## Remaining gates

Fresh installed Classic/Copper HIL deployments and calibration/correction
consumers remain required. The process fixture does not replace those checks.
The native framework separately exercises collision/stale/duplicate, controller
removal and transport/deadline behavior; owner-specific effects and installed
scientific/allocation evidence must retain their own boundaries. Issue #5 is
not closed by these process tests alone.
