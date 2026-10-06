# Shared native owner control prerequisite

RTC-DEV-030; worktree `pipewireao-rtc-native-controls`, branch
`work/native-control-planes-20261005`, starting revision `03f72c1`.
This increment provides the typed transport needed by RTC issues #5–#9.
It does not complete those owner migrations.

## Implementation

`NativeControlClient` extracts the existing runner connection without changing
its wire profile. Multiple dispatch selects each owner's capability namespace,
lifecycle enum, command/result codecs and envelope bound. `NativeRunnerClient`
remains its runner facade. Lifecycle replies retain the 64 KiB bound;
calibration profiles select 128 KiB, including predecode and initial sentinels.
Each connection binds an explicit private remote, expected owner PID and
endpoint instance, full NodeInfo proof, actual global ID and object serial.
The controller marker must be admitted before requests. Requests remain
serialized with one submission, original absolute deadline and no retry/rebind.

`NativeControlEndpoint` is a cold, inactive Filter with no ports or process
callback on the owner's existing Core/ThreadLoop. Callbacks decode and stage one
bounded ticket; the existing owner executes effects outside the native loop
lock. Controller proof comes from full NodeInfo, with bounded live tombstones
for revoked incarnations. The endpoint preserves one accepted slot, one retained
completion and one independent rejection. Stale-token rejection precedes
duplicate matching, as required by the migration design and Rust runner.
An older terminal request remains stale after a newer token is accepted.

Publication failure fences the endpoint. An accepted slot is retained until
terminal publication succeeds; a publication exception cannot be converted to
an invalid-input rejection. Operational entrypoints require a running loop and
a connected, nonfailed Filter. Construction supplies initial parameters to
`connect!`: the native implementation clears earlier parameters on connection.
Decode time consumes the request budget starting at receipt. Cleanup attempts
every resource, preserves the primary constructor exception and aggregates
cleanup failures.

## CPU evidence

Evidence directory: `/home/dgamroth/.cache/rtc-live-controls-20261005`.
Julia 1.12.7, registered PipeWireAO 0.6.16 and its local JLL artifact; fixtures
on CPU 14 with no requested real-time policy. No scientific frame submissions
or DM hardware are involved.

| Check | Result | Log |
| --- | --- | --- |
| Typed profile and envelope boundaries | 23 passed | Included in endpoint logs |
| Explicit empty property changes revoke identity | 5/8 before → 8/8 after | `native-owner-faults-before.log`, `endpoint-faults-final.log` |
| Publication failures retain accepted work and fence effects | 6/15 before → 15/15 after | `native-owner-publication-before.log`, `endpoint-faults-final.log` |
| Stopped owner loop cannot take retained work | Two expected-exception checks failed before; both pass after | `native-owner-loop-before.log`, `native-owner-loop-after-v2.log` |
| Two actual native controller connections, busy/stale rejection, expiry, removal, receipt budget, stopped loop | 36 passed in three fresh serial runs | `native-owner-loop-after-v2.log`, `endpoint-repeat-1.log`, `endpoint-repeat-2.log` |
| Existing runner client on actual Rust endpoint | 46 unit + 58 connected assertions passed | `runner-client-generic-qualified.log` |

The runner executable SHA-256 is
`71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`.
The repeated endpoint proof executes three test effects and no array processing.

## Retained failures and limits

`native-owner-endpoint-after.log` records one SIGSEGV. An unchanged retry passed
32 checks. Review found that the fixtures destroyed owner Core/Context outside
the native loop lock while that loop could run; teardown now holds the lock.
The subsequent three fresh 36-check runs passed. The logs do not establish the
crash's cause; recurrence requires phase markers and a native backtrace rather
than speculative production ownership changes.

`native-owner-loop-after.log` records a startup enum Props failure (-2). Source
inspection confirms `pw_filter_connect` clears the preconnection parameter list;
passing the initial retained parameters addresses this startup gap. The earlier
stopped-loop fail-before fixture also contains a fixture cleanup error from
closing a client during its pending request; the corrected fixture removes its
marker, awaits the request, then closes the client.

`runner-client-generic-final.log` failed because the fixture's required
`NATIVE_RUNNER_BINARY` environment setting was omitted. The corrected invocation
and binary identity are recorded in `runner-client-generic-qualified.log`.
No production behavior was changed for that harness error.

The initial duplicate replay regression requested behavior contrary to the
canonical stale-token rule. Independent review rejected that proposed behavior;
its failed expectation is not a confirmed defect. The final regression tests
the documented rule.

Some initial processes emitted package-version/precompile warnings. A fresh
serialized full regression remains required after integration with the launcher
commit. These mechanism checks do not qualify HEART lifecycle effects,
calibration actions, scientific allocations, throughput, CUDA/HIP or physical
camera-to-DM latency. Actual private-core transport loss and each migrated
owner's effects remain integration gates.
