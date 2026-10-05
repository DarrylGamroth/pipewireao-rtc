# Native live-control migration design

2026-10-05. Proposed narrow implementation design from
[live control inventory](LIVE_CONTROL_INVENTORY.md); the initial source inspection performed no workloads or tests. The design is
now maintained on branch `work/native-control-planes-20261005`, worktree
`pipewireao-rtc-native-controls`, starting at committed RTC revision
`74099a2861ed7d60789a38c0f3ad4121b029bf48`. The separately documented CPU
mechanism proof below does not qualify the proposed production endpoints.

## Decision and scope

Use standard PipeWire Node parameter requests and subscribed parameter events
on public owner endpoints. Requests/completions are ordinary versioned
`SPA_PARAM_Props` objects with `SPA_PROP_params` named fields, containing standard
scalar/Array/Struct PODs. There is no new socket protocol, POD file exchange,
native property ID, daemon-private endpoint, or scientific scheduler.

Keep JSON for persisted configuration, recipes/plans, frozen identities,
captures/manifests, reports and diagnostics. CLI output can render a native
result as JSON. Every live authority currently read from a status/report file
must instead come from the matching native owner completion/query; saved reports
remain independently verified artifacts.

Reuse existing graph run/reset serializers without extending their wire fields.
Reuse `PropsBuffer` for exact prepared numeric fields and the existing ordinary
simulator source-query/snapshot/rejection schema where its semantics apply.
Scientist-facing typed algorithms, graphs, array shapes, calibration and physical
command semantics remain in their current packages.

## 1. Public endpoint mechanism

### Julia cold lifecycle endpoints

Recommend one **inactive Filter with no ports or process callback** for each
existing supervisor, Rust runner, or HEART wrapper that currently lacks a
control node. It is owned by that existing process/dispatcher, not a new lifecycle
owner. No data links, driver flags, timers driving science, dummy frame ports or
processing graph are required.

Public PWA APIs inspected in released PipeWireAO 0.6.16:

| Task | Existing API / source evidence |
| --- | --- |
| Own connection and run callbacks | `ThreadLoop`, `Context`, `CoreConnection`, `with_thread_loop_lock` |
| Publish control node | `Filter(core, name; properties, on_param_changed)` at `src/filter.jl:377`; `connect!(filter; flags=FILTER_ASYNC | FILTER_INACTIVE, params=...)` at `:540` |
| Publish retained snapshots/completions | `update_params!(filter, params)` at `:677`; publish the complete retained Props set together |
| Bind exact public incarnation | `Registry`, `find_globals`, `bind(registry, global, Node; on_info,on_param,on_removed,on_error)` at `src/objects.jl:1005` |
| Request/observe | `set_param!(node, SPA.PARAM_PROPS, pod)` at `:1508`; `subscribe_params!` `:1437`; bounded initial `enum_params!` `:1487` |
| Prepare numeric bodies | `PropsBuffer`, `props!`, `parse_props!`; ordinary cold builder `Pod(props_param(SPA.Props(...)))` at `src/spa.jl:679` |
| Bounded cold variable bodies | `SPA.Array`, `SPA.Struct`, `SPA.Bytes`, String PODs; typed readers via `pod_value` |

Native public implementation inspected in `pipewire/src/pipewire/filter.c:1740`:
connect exports a Node without a minimum-port check, accepts initial global Props,
and respects INACTIVE. Global `set_param` at `:634` only emits `param_changed`;
the owner must publish completion explicitly. A subsequent diagnostic Julia
cross-process private-core proof passed 30/30 assertions, including complete
retained Props, staging without automatic ACK, outside-callback application,
fresh subscribed query completion and removal. See
[Filter mechanism proof](NATIVE_CONTROL_FILTER_PROOF.md) and `native-control-filter-proof.log`.
The subsequent [common-envelope validation](NATIVE_CONTROL_ENVELOPE_VALIDATION.md)
passed 42/42 checks with a Julia client and Rust owner in separate processes.
These diagnostic proofs do not establish production caller authority or installed
qualification.

Filter caveat: the Julia global callback at `src/filter.jl:235` copies parameter
PODs, and `update_params!` builds arrays. These are permitted on cold supervisor,
runner and HEART lifecycle RPC paths. **Do not attach this allocating mechanism
to the measured scientific source control path.** That path already has
`Stream(...; param_buffer=PodBuffer(...), on_param_changed, on_param_overflow)`,
prepared `PropsBuffer`/native run/reset buffers, and
`update_params!(stream, PreparedParams(...))` (`src/stream.jl:606`). Preserve it.

### Rust counterpart

Pinned `pipewire-ao` revision `f2d8689` exposes
`filter::FilterRc::new(CoreRc,...)` (`pipewire/src/filter/rc.rs:51`),
`Filter::connect`/`update_params` (`filter/mod.rs:142`/`:163`), and
`FilterRc` retained listener `.param_changed(...).register()` (`filter/rc.rs:400`).
Node proxy `set_param`/`subscribe_params`/`enum_params` exist at
`pipewire/src/node.rs:97`/`:48`/`:75`. SPA `PodSerializer`, `PodDeserializer`,
`Value::Object/Struct/Array`, `ValueArray::Float/Long`, and public run/reset
builders/parsers already underlie `RTC src/live.rs`.

The current pinned `v0_3_34` feature exposes `INACTIVE`; Rust `ASYNC` is
gated behind `v0_3_77`. The no-port Rust proof uses `INACTIVE` alone, because
there are no buffer queue/dequeue operations. Do not change the deployed crate
feature solely to mirror the Julia flag spelling.

Keep the control Filter on the adapter's existing Core/main loop. Add only a
narrow crate-internal retained Core accessor or endpoint constructor in
`src/live.rs`; do not create another adapter, runner, graph ownership set or
lifecycle machine. Current `LiveGraphAdapter::main_loop()` (`src/live.rs:622`)
already supports embedding. Callback state should contain an owned bounded
pending command and notification; respect the pinned Filter callback's `Send`
bound using safe owned data, rather than capturing thread-local Runner state.

## 2. Ownership and causal completion contract

The following are required field semantics for new supervisor/runner/calibration/
wrapper schemas. The [fixed header contract](NATIVE_CONTROL_ENVELOPE.md) defines the common
namespace, exact scalar types and unsigned bit-pattern representation.
Owner-specific operation enums and payload schemas remain separate reviewed
contracts; they are not inferred from diagnostic operation IDs.

| Field | Representation / rule |
| --- | --- |
| Protocol version | exact SPA Int, known version only |
| Owner endpoint instance | positive SPA Long, new at process/endpoint creation |
| Controller identity | native caller Client/Node global ID + object.serial + caller instance, bound to its real registry lifetime where hold/disconnect semantics require it |
| Request token | positive SPA Long; never reused within an endpoint incarnation; exhaustion rejects |
| Operation / result kind | fixed reviewed SPA Id or Int enums, exact types |
| Target | declared graph/group/parameter identity; bounded String or cold catalog ID with checked catalog generation; never guess global ID from a name alone |
| Relative remaining budget | positive SPA Long nanoseconds; receiver bounds against allowed budget; client keeps original absolute deadline |
| Completion | endpoint instance + exact controller identity + token + operation + typed result/outcome/state; zero or negative result; rejection independent of last committed ACK |
| Observation cursor | relevant generation/sequence/active/requested/report cursor; exact integer semantics |
| Payload | bounded native POD arrays/structs with exact profile, element types, dimensions/counts and result kind |

Clients bind exactly one named endpoint on the explicit private remote and verify
expected process PID, protocol advertisement, endpoint instance, global ID and
`object.serial` via NodeInfo/registry identity. Every staged request names the
expected endpoint instance. Core/proxy error, removal, changed serial/global ID,
unexpected owner generation, malformed completion or deadline expiry produces
unknown outcome/failure. Do not rebind, resend, create a replacement owner or fall
back to JSON files/sockets during the same control operation or cleanup.

Calibration Hold must also bind and monitor the controller's actual native registry
incarnation for that transaction. Node parameter callbacks do not identify their
setter connection by themselves. Include and validate controller object identity in
the new envelope, completion and rejection and retain its registry/proxy removal listener. Loss
of that controller must fault or retain held authority as the current socket
disconnect does; a claimed client number alone is insufficient. This is cold
control metadata and creates no scientific processing owner.

Calibration additionally retains a finite next-request inactivity deadline, set
when the preceding request is accepted. Existing socket code starts its next
reader before executing the current action. Native transport must not extend
that budget by starting it after completion. A live but silent controller must
fault or retain hold when that deadline expires. The controller lifetime marker
is scoped to the calibration run and is removed on abort even if its Core remains
connected. Do not permit pipelining a second acquisition action.

Keep one pending request slot per serialized owner, one last committed terminal
completion and one bounded independent rejection. Reject busy/stale/malformed
requests without replacing accepted state. Duplicate of the last committed
request retains its original terminal result only for the same controller global
ID, object.serial and instance, token, operation and canonical payload. A
different controller selecting the same token receives a correlated rejection;
it cannot accept the first controller's completion. Same token with a different
operation or payload is invalid. Once a newer token is accepted, older tokens are stale.
Tokens on new cold public endpoints should be globally monotonic per incarnation;
operator clients can use retained next-token/last-token metadata to select a token,
but concurrent collisions reject rather than retry automatically. Token allocation
metadata is not a fresh status completion. Scientific run/reset remain exclusively
coordinated by the existing supervisor and keep their established token format.

The callback validates/copies or decodes only bounded data, stages the slot and
returns. It must not execute Runner effects, wait on another node, prepare science,
write reports, adopt a probe, or reset a model. The **existing sole serialized owner**
takes the slot after callbacks return, performs the operation at its existing causal
boundary, then publishes completion. Do not hold the endpoint loop lock while
waiting on downstream controls or executing science. Rust already follows this
dispatch separation in `src/main.rs:155`: preserve it while replacing socket
submission/reply plumbing with parameter staging/publication.

Completion means the same thing as today's owner result:

- Runner session operations: expected lifecycle state reached after owned effects;
  group/property/parameter results retain requested/submitted/active distinctions.
- Source pause: outstanding command adopted, cursor frozen; no artificial partial
  report requirement. Reset: reset actually completed and generation/cursor truthful.
- HEART wrapper reset: old child stopped and replacement prepared/placement checked;
  child generation increments. Never represent node set_param return as child restart.
- Calibration: adopted/settled/collected/restored evidence comes from the existing
  AcquisitionSession/CalibrationServer effect boundary, with exact exposure identity.
  Release requires restoration; unknown client outcome does not release held authority.
- Status: a matching newly processed query token, not a replayed enum/cache sample.

## 3. Deadlines and bootstrap

### Finite execution

Separate bounded cold discovery/static compilation from every real mutation/query.
Use one absolute client deadline for staging, downstream execution and matching
completion observation. Nested effects receive the remaining budget, capped by
their existing local maximum; they must not restart an eight/five-second budget.
Queued expiry must be rejected before effects. In-flight expiry retains truthful
hold/fault state and cannot claim rollback or success.

**Confirmed baseline prerequisite:** the inspected starting `roundtrip()` used
`main_loop.run()` without a timeout, even inside nominally finite outer loops.
The [synchronization correction](NATIVE_CONTROL_SYNC_VALIDATION.md) now has
stalled-core fail-before/pass-after evidence. It uses exact Core sync callbacks
and finite `Loop::iterate`, propagating local observation/cleanup deadlines.
The production endpoint must still carry one remaining request budget through
preparation, all effects and completion, with a separately defined restoration
budget. Local finite waits alone do not establish that whole-request boundary.

### Startup before operator broker readiness

Retain the current DeploymentRunner as sole supervisor. It creates the private
core first; then its own inactive control endpoint on that core. Advertise a
Preparing snapshot but reject public mutations until coherent admission succeeds.
Spawn the same owners and same Rust runner, now passing explicit private remote,
endpoint name and expected instance/identity prerequisites instead of socket paths.
Owners that prepare before data-stream creation can publish a separate cold
no-port readiness endpoint; it reports Preparing/Prepared/Connected/Failed and
never participates in frame scheduling. Existing scientific source streams still
own their hot run/reset/query parameters once connected.

The supervisor observes native readiness and process liveness under an overall
preparation deadline, starts the runner through its native control endpoint, then
releases source ingress through the established source protocol. Only afterward
does its public endpoint advertise Admitted/Ready. It then stages ordinary operator
requests to the existing `coordinate` function outside callbacks.

Before a process publishes any endpoint, process exit and the preparation deadline
remain authoritative. Failure diagnostics can be saved JSON/stderr; shutdown can
use bounded supervised process signaling when no native endpoint ever existed.
Do not require reading a JSON readiness/report file to admit the process. A runtime
locator may remain persisted configuration identifying private remote/node name;
fresh native owner metadata/completion, not its saved PID/admitted flag, validates
the current instance. Avoid an extra broker process or new owner state machine.

## 4. Calibration variable payload: smallest first implementation

Use **bounded native SPA arrays inside the calibration request/completion Props**
initially. Figures are always 277 Float32 elements (1112 payload bytes); mean
responses are 376 Float32 (Classic) or 3600 Float32 (Copper). This avoids extra
control data streams/links and their two-channel adoption protocol for these small
cold RPC payloads. `SPA.Array{Float32}` and Rust `ValueArray::Float` are existing
public serializers. Do not put JSON text into a String/Bytes POD.

Use typed scalar/Struct/Array exposure records containing domain/generation/
sequence/start_model_ns/duration_ns, plus exact record count and profile. Keep
the existing action kinds and settling semantics from the inventory. Run, serial,
generation and sequence currently allow UInt64. Preserve all 64 bits using a
reviewed explicit native representation (recommend SPA Long bit-pattern
reinterpretation, with unsigned comparisons after decode), rather than silently
reducing the range. Budget/model-time values retain their existing positive signed
range. Implement cross-language boundary values before admitting this codec.

Cold parsers/builders can allocate, but only after POD length/type/count bounds are
checked. Preserve current request ≤16 KiB and result ≤128 KiB limits in the first
native contract; align the Julia capture client with that one documented result
bound rather than retaining its divergent 64 KiB socket reader. Keep MAX_FRAMES
4096 as an upper semantic bound, and **preflight encoded result capacity** for the
selected action/profile/frame count before effect submission. The byte limit may
impose a smaller collect limit, as the current wire format already does. All size
arithmetic is checked; reject impossible capacity before changing the held figure
or acquiring exposures. No unbounded result list, callback decode or staging queue.

For Capture, native completion carries bounded relative manifest name, SHA-256,
frame count, payload/metadata byte counts and completion cursor. Immutable captured
ndarrays/manifest remain saved artifacts; completion is published only after their
existing commit boundary. Actual figure/mean arrays and exposure metadata are live
native payloads, not report-file reads.

Only introduce public NdArraySource/NdArraySink transfer if a later admitted payload
exceeds this bounded POD contract. Existing public APIs are
`submit_array!`/`arm_array_sink!`/`wait_array_source!`/`wait_array_sink!`
(`PWA src/ndarray_exchange.jl:391`/`:434`/`:486`/`:509`). Such a phase must correlate
payload publication and receiver adoption to run/serial/incarnation; source queue
publication alone is not owner application. It is unnecessary for the fixed figure
and mean payloads above and should not delay their migration.

No new frame-rate callback, per-frame serialization, allocation, report polling or
extra scientific transport is added. Scientific calibration exposure acquisition
continues through the current typed AcquisitionSession/HEART bridge. Cold action
encoding is separate from any steady-state frame allocation contract; when controls
are inside an inclusive owner gate, retain the existing prepared source codec and
include their actual costs in that gate.

## 5. Dependency-ordered implementation phases

| Phase | Narrow files/contracts | Completion gate and current evidence |
| --- | --- | --- |
| A. Transport proof + shared envelope | Implemented Julia/Rust fixed-header codecs and diagnostic endpoint use PWA public APIs. The common namespace, incarnation, token, result, bounds and UInt64 representation are specified; production operation enums and payloads remain owner contracts. | Diagnostic Julia↔Rust private-core proof passes 42/42: exact endpoint discovery, retained three Props, staged adoption, subscribed completion/query, duplicate and conflicting-identity rejection, unsupported operation and removal; no ports/process callback/links/frames. Codec tests cover malformed envelopes. Remaining gates: busy/stale/queued-expiry behavior, two actual controller connections, registry-bound caller authority and disconnect/inactivity handling; diagnostic finite waits do not prove production owner execution deadlines. |
| B. Runner deadline prerequisite and endpoint | `src/live.rs`, `src/main.rs`, `src/control.rs`; replace socket ingress/reply with staged native commands while retaining `Runner`, Statig and typed commands. `src/control_socket.rs` removed only after callers migrate. | Fail-before/pass-after bounded sync stall/removal; existing lifecycle/group/property/parameter outcomes and ownership cleanup unchanged; exact run/reset wrappers preserved. |
| C. Supervisor internal controls and HEART wrapper | `deployment/julia/src/deploy.jl` internal `native_control`, `heart_owner.jl`; simulator `reset_controller!`; HEART exporters. Replace runner socket and HEART reset/status files first; use preparing/ready/admitted native state. | CPU startup held, runner readiness/start, source release, pause/reset/restart, process identity change, failed child restart and finite cleanup. Keep public operator socket temporarily as unmigrated ingress; no hidden native→JSON fallback. |
| D. Calibration/correction lifecycle controls | `deployment/hil/calibration_owner.jl`, `heart_calibration_owner.jl`, `heart_correction_owner.jl`; `calibration_export.jl` / HEART exporters; reuse source codecs where semantics match. | Native admission/pause/status, unsupported calibration reset, restoration/hold and report cursor; remove file-control override only when each actual owner supports the ad. HEART health authority comes from native wrapper, full status report retained as artifact. |
| E. Calibration action endpoint and clients | Refactor only framing/dispatch adapter in `calibration_server.jl`; keep `execute!`/`effect!`/AcquisitionSession. Add native `CalibrationEndpoint` implementation in Rust alongside current trait; switch `rtc-calibrate`. Migrate `CalibrationCampaign.Endpoint` and HEART pilot/full-plan callers. | Cross-language exact fields/Float32/UInt64, encoded capacity preflight, Hold→Adopt→Settle→Collect/Capture→Restore→Release, clipping/rejection, causal exposures, artifact commit, deadline/disconnect leaves hold/fault and no retry. |
| F. Public operator and final live-file removal | `deploy.jl:control/serve_control/coordinate`, Rust CLI `main.rs:run_client`, CLI/install/export contracts; startup readiness/state polling helpers and docs. | One ordinary private-core deployment path serves native operator controls, native runner, native source/calibration/wrapper, including startup/cleanup. Retire live JSON socket/file transports and fallback selection. Saved artifacts/CLI rendering remain separate. |

Each phase exposes one reviewable contract and a CPU integration gate before an
installed scientific campaign. No all-at-once graph/owner rewrite is needed.
RTC-DEV-030 now specifies native local live controls; the remaining calibration
JSON implementation is migration debt rather than admitted native capability. Hardware/GPU,
allocation and installed qualification remain separate required evidence when their
affected paths are implemented.

## Remaining decisions and limits

- No-port inactive Filter suitability has Julia and Rust cross-process mechanism
  proofs, documented in [Filter mechanism proof](NATIVE_CONTROL_FILTER_PROOF.md).
  The subsequent Julia-client/Rust-owner [common-envelope proof](NATIVE_CONTROL_ENVELOPE_VALIDATION.md)
  passes 42/42 diagnostic checks. It uses synthetic controller identities and does
  not establish registry-bound authority, two actual caller connections, busy/stale
  admission, calibration hold/disconnect/inactivity handling or production effects.
- The fixed header and unsigned bit-pattern representation are specified in
  [the common envelope](NATIVE_CONTROL_ENVELOPE.md) and exercised across Julia/Rust.
  Production owner-specific enums, payload/catalog identity and authenticated
  controller lifetime remain implementation and integration gates.
- Rust inner synchronization is now locally bounded with separate
  [failure evidence](NATIVE_CONTROL_SYNC_VALIDATION.md). Full finite control still
  requires whole-request budget integration; timing out a client is insufficient.
- Existing vendor HEART TCP commands and binary telemetry remain external HEART
  interfaces; replacing the wrapper's JSON control/health IPC does not claim to
  redesign the vendor command server or its science.
