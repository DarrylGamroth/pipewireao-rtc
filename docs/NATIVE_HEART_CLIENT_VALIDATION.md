# Native HEART client validation

## Scope

`deployment/julia/test/native_heart_client.jl` is a CPU fixture for the native
HEART profile, shared native-control endpoint/client, and
`NativeHeartClient` wrappers. It uses a private PipeWireAO core and actual
subscribed SDK clients. Its owner dispatcher starts and replaces an owned
`sleep` subprocess to provide a real child PID and process lifecycle.

A separate short private-core fixture exercises the wrapper lifecycle from
`Preparing` through `Ready`, acknowledges `connect`, and shuts down the owned
sleep child. It has its own endpoint so its terminal `Stopped` state does not
affect the retained removal and core-loss cases.

The fixture does not launch the vendor HEART executable or HEART TCP client,
create WFS/DM endpoints, process pixels, perform reconstruction or integration,
or exercise transport frames. The sleep child and generation report are test
fixtures only. Passing this test does not qualify the HEART wrapper, its
scientific behavior, ingress, placement, timing, or live calibration/correction
consumers.

## Checks

The fixture checks exact owner PID and endpoint-instance admission, including
rejection of a wrong PID, wrong instance, and wrong owner profile. It obtains a
fresh typed status completion, reads the saved generation report identified by
that completion, and verifies its SHA-256 and owner/generation/child identities.

It then checks a negative completion with an explicit absent snapshot while the
owner remains Ready and its child remains alive. A successful Reset completion
must report the next generation and replacement child. `require_ready` must
reject the earlier snapshot. Separate requests exercise controller removal and
private-core transport loss after staging; both must yield `UnknownOutcome`
without another owner effect, reconnect, or retry.

The separate lifecycle fixture begins in `Preparing`, observes a verified
controller, remains `Preparing` for a bounded interval, and then publishes
`Ready` asynchronously. It verifies that client admission waits for that transition,
that `connect!` returns the same child PID and generation, and that `shutdown!`
returns a `Stopped` snapshot only after the actual fixture subprocess has
exited.

## Evidence

Run the fixture with the repository Julia project. It writes a compact
`summary.json` and the generation reports under
`$HOME/.cache/rtc-live-controls-20261005/native-heart-client-*` by default;
`NATIVE_HEART_EVIDENCE` can select another evidence root. The test output and
summary identify the owner PID, endpoint and controller identities, child PIDs,
and report hashes.

## Result

The original standalone fixture passed **44/44** checks on CPU15 with Julia
1.12.7. The added NH001 regression sequence then reproduced the stale-health
gap against the pre-fix production client: after generation 1 was reset to
generation 2, a later failed completion retained lifecycle `Ready` with an
absent snapshot, and `require_ready` accepted the old generation 1 snapshot.
The fail-before fixture result was **53 passed, 1 failed, 0 errored**. The
single expected failure was `@test_throws ErrorException
HeartClient.require_ready(client, first_snapshot)` at the post-reset failure
case.

Fail-before output is preserved at
`/home/dgamroth/.cache/rtc-live-controls-20261005/native-heart-client-fail-before-20261006.log`;
the accompanying report evidence is in
`/home/dgamroth/.cache/rtc-live-controls-20261005/native-heart-client-2038287844364872/`.

The fail-before command was:

```sh
timeout 180s taskset -c 15 env OPENBLAS_NUM_THREADS=1 JULIA_NUM_THREADS=1 \
  julia --threads=1 --startup-file=no --project=deployment/julia \
  deployment/julia/test/native_heart_client.jl
```

The earlier 44-check passing evidence is in
`/home/dgamroth/.cache/rtc-live-controls-20261005/native-heart-client-2038094386917860/`.
The regression fail-before summary records owner PID 3521774, endpoint instance
2038293664400985, controller global ID 15/serial 21, generations 1→2, and sleep
child PIDs 3521819 and 3521845. Its report digests are `362a2f0c646a55836c35077ae733c309f4dc63cffc8ce9f48dca65bac5261cc9` and
`84f19fb1ab7b1351297b8a34367ca853f6026e8f1979ac2f50d2fdb9e083bd12`.

After the client correction, the same fixture passed **54/54** checks on CPU15.
The failed Ready/None completion now makes `require_ready` return
`UnknownOutcome`; a new successful status restores health checks for generation
2, while generation 1 remains rejected. The original generation 1 failed
completion also returns `UnknownOutcome` until the fresh query.

Post-fix output is preserved at
`/home/dgamroth/.cache/rtc-live-controls-20261005/native-heart-client-post-fix-20261006.log`;
the post-fix summary and reports are in
`/home/dgamroth/.cache/rtc-live-controls-20261005/native-heart-client-2038358824876979/`.
That summary records owner PID 3522286, endpoint instance 2038364759228252,
controller global ID 15/serial 21, generations 1→2, and sleep child PIDs
3522375 and 3522422. The report SHA-256 values are
`0cc396314b48460842c1b71bf351b1a8c0fa069f8213268d36c4a6d454c066ce` and
`ea2f9dff29a3703ce17d12ab870c62b6d8c8a35908f0633628573b828d49f9af`.
Both sleep children exited, and both report digests were checked against the
saved report bytes.

This is CPU software transport evidence only. The fixture uses no vendor HEART
executable, HEART protocol client, scientific algorithm, ndarray traffic,
placement qualification, or timing/rate measurement. Unchanged-vendor HEART
qualification remains a separate gate under RTC-DEV-030.

The lifecycle extension preserves the original **54/54** checks and adds a
separate private-core fixture with **16/16** checks on CPU15 with Julia 1.12.7.
It observed asynchronous `Preparing`→`Ready` publication, a successful connect
completion carrying the same generation and child PID, and a `Stopped`
nonalive completion after the owned sleep child exited. The run used the
command above; its first fixture evidence directory is
`/home/dgamroth/.cache/rtc-live-controls-20261005/native-heart-client-2039364002334281/`.
The lifecycle-only fixture does not write a second summary file; its assertions
are recorded in the test output.
