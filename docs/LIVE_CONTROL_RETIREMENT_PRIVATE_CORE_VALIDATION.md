# Rust retirement: actual private-core validation

## Source and scope

2026-10-06, clean starting revision `cebe0a568ac541826ee461a1aad03f3339c7c352`,
branch `audit/live-control-retirement-20261006`, worktree
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-jfg-sdk`.
This follows [NRET-001/NRET-002 removal and pure verification](LIVE_CONTROL_RETIREMENT_REMEDIATION.md).
No production source changed in this qualification increment.

All processes inherited CPU11 affinity. Julia 1.12.7 used one Julia thread,
`OPENBLAS_NUM_THREADS=1`, `JULIA_PKG_OFFLINE=true`, and
`LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu`. Each driver created and
removed its own private core. No existing core, scientific AOS owner, HEART
owner, physical endpoint or installed service was operated.

The current shared target is
`~/.cache/rtc-live-controls-20261005/native-filter-target`.
Exact executable SHA256:

| Executable | SHA256 |
| --- | --- |
| `debug/pipewireao-rtc` | `7968051f1d4d591414f6cffb995f6efbacc4099ccb881bd3a268e67423f9a341` |
| `debug/rtc-calibrate` | `ce0ba26cf04f64ea1cb730c4b89309592c5097843cc326d867c4ddd1bfe9b1cb` |

The current library and runner test executables are respectively
`debug/deps/pipewireao_rtc-4cee2cf8cb150278` and
`debug/deps/pipewireao_rtc-efaa902bedb6b6fe`. They are the same executables from
the focused retirement build. The only additional Cargo build was the tiny
current-source `native_sync_deadline_proof` example, offline, one job, debug0,
incremental disabled, existing target and dependency flags; it completed in
0.2 seconds. No dependency download or new target was used.

## Seven previously ignored Rust tests

All seven ran with `--exact --ignored --nocapture --test-threads=1` and passed.
The Rust assertions were unchanged. Julia driver totals below include driver
assertions and must not be added to the seven Rust test count as new Rust tests.

| Rust fixture | Driver/evidence | Observed result |
| --- | --- | --- |
| `pending_preparation_is_fenced_by_required_object_loss` | `native_runner_monitor.jl` | Required node loss faults staged preparation, releases accepted slot and does not dispatch late result. |
| `queued_request_is_fenced_by_required_object_loss` | Same driver | Required node loss fences the queued request. |
| `accepted_runner_request_inherits_stalled_core_budget` | Same driver | 250 ms accepted deadline expires; elapsed 250,054,147 ns; no session-start effects. |
| `queued_request_bounds_due_monitor` | Same driver | Queued monitor respects 250 ms budget; elapsed 250,124,429 ns; no session-start effects. |
| `dropped_clean_adapter_does_not_start_new_sync` | `native_runner_destructor.jl` | Clean adapter drop took 256,900 ns, below the fixture 250 ms bound. |
| `stopped_core_bounds_discovery_and_cleanup` | `native_sync_deadline_proof.jl` | Discovery and cleanup return unknown/error within their stated budgets; old acknowledgements cannot complete a newer synchronization. |
| `property_rejections_preserve_ready_and_running_sessions` | Owned tiny property fixture | Ready/Running property rejection, submitted/adopted generation behavior, execution-group pause/reset checks pass on actual native graph. |

Monitor driver: **12/12**; sync driver: **34/34**, including the additional
current-source example probes. These stopped only their own disposable daemon.
The four monitor/budget tests use actual core objects but inject controller
identity into the endpoint staging seam to choose an exact interleaving. They
prove fencing, liveness and bounded waits; they do not prove actual registry
caller authority. The stopped-core timings are functional timeout bounds,
not scheduling-jitter or latency qualification.

### Property fixture prerequisites

The existing ignored test requests a looping graph, parameter, integrator
properties and an execution group. A cache-only fixture supplies four two-value
FITS samples, a 2×2 identity reconstructor, a two-output native graph and a
non-actuating discard sink at 10 Hz. This is toy native control exercise,
not scientific optics or numerical qualification.

Its private-core helper is a copy of the existing helper with the `/opt`
plugin prefix and public SPA-node-factory/device mappings enabled. The graph
module receives the exact private `PIPEWIREAO_REMOTE`; link-factory allows the
existing explicitly passive parameter link. No transport callback, library
private layout or test assertion changed.

Six earlier setup attempts are preserved under
`retirement-property-fixture-20261006/attempt-*`: literal plugin paths rejected
by maintained configuration rules; missing server SPA factory; JLL prefix lacks
device plugin; generic graph creation failure before debug evidence; delegated
module lacked the exact private remote; factory did not permit passive links.
These are rejected fixture assumptions, not confirmed production defects.
The final unchanged Rust test passed in 0.37 seconds.

## Actual caller and completion evidence

Separate existing actual endpoint drivers fill the authority coverage gap:

- `native_runner_endpoint.jl`: **143/143**, current runner, two actual exported
  controllers, exact registry identity, malformed/duplicate/conflicting/stale
  requests, removed caller and quit cleanup. Held synthetic arrays;
  `source_submissions=0`, `sink_arms=0`.
- `native_runner_client.jl`: **58/58 actual endpoint checks**, two actual typed
  clients, plus **46/46 pure bounded-observation checks**. No source submission
  or sink arm.
- Existing cache `native-calibration-rust-interop.jl`: **21/21**, current
  `rtc-calibrate` to actual Julia native action endpoint with synthetic
  acquisition. Wrong PID and wrong incarnation reject before hold/adoption;
  exact binding completes the matched run, confirms restoration and resume,
  retains the typed responses, closes action ingress after terminal flush and
  leaves the lifecycle endpoint open. No `calibration.sock` is created.
  This proves native adapter completion, not a deployed calibration campaign.

The first calibration attempt failed before tests because the deployment
project lacks `AdaptiveOpticsSim`, required by the fixture definitions. The
rerun used the existing installed HIL dependency project
`~/.cache/rtc-native-final-deployment-20261006/classic-fgn-v6-installed/hil`
with `--compiled-modules=existing`; no resolve, instantiate or science owner.
The cache script explicitly loads source `PipeWireAO.jl` revision
`6e4e1eebf8bd160f01a532dcfc7284dec92de61b`, then the current deployment module.
This source-SDK fixture is deliberately distinguished from installed SDK
qualification. The regular deployment project selects PipeWireAO 0.6.16 and
JLL 1.7.0+19. Most private cores use that JLL artifact; the toy device fixture
uses `/opt/pipewireao`. Actual daemon/library/device/bundle hashes are retained.

## Reproduction and retained evidence

Cache root: `~/.cache/rtc-live-controls-20261005/`. Full source, executable,
configuration, plugin and log hashes (97 files) are in
`retirement-private-core-evidence-sha256-20261006.json`, SHA256
`960b502565cb8b30950af8635d5c5b653a4dcd8ae157e21efc3c46cad6e3a34c`.

Run from the worktree with the environment above and `taskset -c 11`:

```text
NATIVE_RUNNER_BIN_TEST_BINARY=<current runner test executable>
NATIVE_RUNNER_LIB_TEST_BINARY=<current library test executable>
NATIVE_RUNNER_BINARY=<current runner>
NATIVE_RUNNER_CPU=11
julia --startup-file=no --project=deployment/julia deployment/julia/test/native_runner_monitor.jl
julia --startup-file=no --project=deployment/julia deployment/julia/test/native_runner_destructor.jl
NATIVE_SYNC_DEADLINE_PROOF=<target>/debug/examples/native_sync_deadline_proof
NATIVE_SYNC_DEADLINE_TEST_BINARY=<current library test executable>
julia --startup-file=no --project=deployment/julia deployment/julia/test/native_sync_deadline_proof.jl
julia --startup-file=no --project=deployment/julia deployment/julia/test/native_runner_endpoint.jl
julia --startup-file=no --project=deployment/julia deployment/julia/test/native_runner_client.jl
```

Set each driver's corresponding `*_EVIDENCE` variable to a new owned cache
path. The property fixture retains `run.jl`, `private_core.jl`, `session.conf`,
`graph.conf`, FITS data and reconstructor in
`retirement-property-fixture-20261006/`. Its runner additionally needs:

```text
PIPEWIREAO_FITS_PLUGIN=/opt/pipewireao/lib/x86_64-linux-gnu/spa-ao-0.2/fits/libspa-fits.so
PIPEWIREAO_DISCARD_PLUGIN=/opt/pipewireao/lib/x86_64-linux-gnu/spa-ao-0.2/discard/libspa-pipewireao-discard.so
PIPEWIREAO_RTC_GRAPH_PROPERTY=<fixture>/graph.conf
PIPEWIREAO_RTC_FITS_PATH_PROPERTY=<fixture>/slopes.fits
PIPEWIREAO_RTC_PARAMETER_PROPERTY=<fixture>/reconstructor.f32le
RETIREMENT_PROPERTY_CONFIG=<fixture>/session.conf
RETIREMENT_PROPERTY_EVIDENCE=<fixture>
julia --startup-file=no --project=deployment/julia <fixture>/run.jl
```

Calibration rerun:

```text
REVIEW_SOURCE_ROOT=<current worktree>
PIPEWIREAO_RTC_CALIBRATE_TEST_BINARY=<current rtc-calibrate>
julia --startup-file=no --compiled-modules=existing \
  --project=<installed>/hil <cache>/native-calibration-rust-interop.jl
```

Top-level logs are `retirement-private-core-monitor-20261006.log`,
`retirement-private-core-drop-20261006.log`,
`retirement-native-sync-private-core-20261006.log`,
`retirement-private-property-20261006.log`,
`retirement-actual-runner-endpoint-20261006.log`,
`retirement-actual-runner-client-20261006.log` and
`retirement-native-calibration-interop-warm-20261006.log`.
The failed calibration prerequisite log remains separately retained.
Child Rust logs and private-core configurations/logs remain in the corresponding
cache directories. Synchronization marker files in deadline fixtures are
fixture diagnostics only; they are not production control authority or fallback.

## Disposition and remaining gates

Observed: all seven ignored Rust fixtures and the additional actual native
caller/completion checks passed without a production fix. All owned children
were closed; CPU11 was released. This evidence closes the previously unexecuted
software private-core test gap. The earlier **130 pure/focused tests** remain
separate evidence, not a claim that those tests exercised an actual core.

Independent retirement diff review and primary updated installed
foreground/service qualification remain separate gates. No scientific
convergence, allocation, sustained throughput, uninstrumented latency, physical
hardware or full issue #7/#8/#9 completion is claimed. Other retirement findings
remain outside this approved increment.
