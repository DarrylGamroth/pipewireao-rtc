# Deployment package architecture review

**Latest disposition:** the final verification checkpoint below reviews RTC
commit `50dc370`. DEP-012, DEP-013 and DEP-014 are remediated within the stated
source and functional scope. All eight final installed profiles have the
expected command counts and clean shutdown. Earlier sections are dated
checkpoints and retain their original open gates; the final checkpoint
supersedes those gates without expanding the evidence into numerical, timing
or hardware qualification.

## Scope and disposition

Independent source review on 2026-10-01 in `pipewireao-rtc-deployment`, branch
`work/deployment-20261001`, starting at `7122d1c`. The tree was clean at initial
inspection. This review adds only this document; no build, replay, deployment,
or timing qualification was performed.

The user has promoted a deployment package into scope: standard SPA-JSON assets,
installation/export, foreground and user-service operation, separate private
PipeWire / external Julia owner / RTC processes, placement before ingress,
and bounded local control with generation and health observations. AOS/HIL
integration is a subsequent increment. Physical device authority, remote
control and scientific changes are not included. Existing AGENTS.md and active
documents still describe a narrower baseline; their exclusions are historical
constraints to update deliberately under this authorization, not a reason to
reactivate the full archived architecture.

**Disposition:** the proposed process separation is compatible with the existing
one-owner Statig lifecycle and public PipeWire contracts. Implementation should
begin with the contracts and slices below. Readiness and bounded control are
required design work, not behavior supplied by wrapping the current executable
in service units. Findings below are confirmed gaps relative to the newly
requested deployment contract, not claims that the existing development tool
violates its former contract.

## Mandatory contract proposal

These are proposed acceptance conditions for primary-agent adjudication before
implementation. Add new active architecture/operating IDs without changing the
meaning of existing IDs, and update the active authority map.

| Boundary | Required behavior |
| --- | --- |
| Scientific graph | Preserve standard PipeWire relaxed SPA-JSON and the maintained native/JFG generators. Do not parse or reinterpret `filter.graph` scientific operations in RTC. |
| Package | Export explicit config, graph, calibration references, profile and executable/environment paths. Record versions/hashes and unresolved dependencies. Install into a selected prefix without implicitly starting or enabling services. No second scientific graph schema. |
| Processes | Private core owns transport; native graph host owns FGN execution; external owner owns Julia initialization, compilation and workers; RTC owns exact session realization and serialized lifecycle. |
| Start admission | Load and inspect exact objects/ports/links, prepare owners, verify requested effective placement/resources, then allow an explicit session start and external source release. Fail closed on a missing readiness stage. |
| Ingress | The source owner must support a held state before release. RTC graph READY does not imply that an application-owned source is held. Restart or dependency loss must revoke the previous admission. |
| Commands | One typed parser/executor serves stdin and Unix-socket front ends. Only the serialized RTC owner accesses Runner/LiveGraphAdapter. Socket/file workers exchange owned bounded messages. |
| Replies | Return structured request identity, result/rejection, lifecycle state and session identity. Distinguish submitted, requested and active generations. A disconnected client does not imply rollback or safe retry. |
| Bounds | Specify finite clients, request bytes, decoded fields, queued requests, prepared parameter bytes, response bytes and read/write/preparation timeouts. Full queues reject or apply bounded backpressure outside the owner. |
| Observation | Health includes lifecycle, required-object status, observation timestamp, busy/pending command and diagnostic. Unsupported or unobserved generations remain unknown. Health is not science or timing qualification. |
| Shutdown | SIGTERM/control shutdown stops owned execution then unloads owned objects, with bounded supervisor fallback. Stop source admission before tearing down its consumers. Client disconnect alone does not stop the service. |
| Services | Same installed commands/configs as foreground. Dependency ordering is supplemented by explicit readiness. Dependency restart requires fresh realization/admission, not automatic reuse of old node identities or generation observations. |
| Placement | Exclude CPUs 0/1 in maintained host profiles; source12 and housekeeping14 remain as requested. Process masks are envelopes; libraries own worker affinity/FIFO and locking. Verify actual threads before ingress. |

The control protocol may encode requests/replies independently of SPA-JSON;
that does not justify inventing another graph-authoring format. Prefer a small
versioned local protocol over scraping the executable's human Debug output.

## Ownership and execution map

```text
socket/stdin reader -> bounded prepared command -> sole RTC dispatcher
    -> typed lifecycle effect -> public PipeWire owner/graph contract
    -> observed completion/generation -> bounded response -> client writer

held source -> public PipeWire transport -> FGN host OR external Julia graph
    -> non-actuating sink/observer
```

No control listener, service supervisor or readiness script performs science,
forwards every frame, allocates frame buffers, pins individual workers behind
their library's back, or creates another data-plane scheduler. Control work can
still interfere through CPU, memory or the serialized owner; bound and observe
it rather than calling it free because it is outside callbacks.

## Findings

### DEP-001 — Startup must separate loaded readiness from ingress admission

- **Severity:** high. **Confidence:** high. **Status:** implementation prerequisite.
- **Evidence:** `src/main.rs::run` dispatches Start immediately after Load and
  printing READY, before entering the control loop. `src/live.rs::start` starts
  graphs in reverse order and waits for links; it is not a deployment placement
  verifier. `src/config.rs::validate_source` rejects session run control for an
  external source: source run control stays application-owned.
- **Impact:** an ExecStart wrapper or a READY log line alone cannot guarantee
  that placement checks precede frames, or that a source cannot run while the
  controller is still initializing. Startup PID/socket existence is insufficient.
- **Required remedy:** explicit load-only/service startup; source-owner hold and
  release contract; readiness tied to current instance/core identity, exact
  topology and effective placement. Preserve existing interactive behavior only
  where explicitly selected. A stale readiness file must not release a new run.
- **Validation:** source remains silent before admission; delayed/missing owner,
  wrong port/schema, bad placement and stale readiness all prevent release;
  normal start succeeds; dependency loss and restart require fresh admission.

### DEP-002 — Reusing the current stdin queue would not provide bounded control

- **Severity:** high. **Confidence:** high. **Status:** implementation prerequisite.
- **Evidence:** `src/main.rs::control_session` uses `read_line`, a PipeWire
  channel and `VecDeque`. `send_prepared_control_input` waits for acknowledgement
  only for parameter commands. `prepare_control_input` reads the entire file
  with `std::fs::read`; the existing one-parameter-in-flight bound is not a byte
  bound. Ordinary command traffic can accumulate without that acknowledgement.
- **Impact:** a local client can exhaust memory or create long command residence;
  slow reply readers can stall the owner if socket writes occur on it.
- **Required remedy:** finite admission and byte limits before allocation;
  checked dimensions/type/byte-length arithmetic; one bounded preparation path;
  finite reply queues and client deadlines; no socket or filesystem blocking on
  the Runner owner. Keep a strict queue-order policy for accepted mutations.
  Socket parent directory/socket permissions must restrict access to the owning
  user; reject unsafe existing path objects rather than unlinking arbitrary files.
- **Validation:** oversized lines/files, overflowing dimensions, partial clients,
  flood, queue full, slow reader, disconnect and shutdown while preparation is
  blocked; memory stays bounded and required-object polling continues. Invalid
  requests should produce request rejection rather than terminate a healthy
  service through the existing stdin PreparationFailed exit path.

### DEP-003 — Generation adoption and control responsiveness need separate bounds

- **Severity:** high. **Confidence:** high. **Status:** contract decision required.
- **Evidence:** `src/live.rs::update_properties` waits for running active
  generations with a five-second deadline. Stopped updates return Submitted.
  `LifecycleEffect::UpdateParameter` returns ParameterSubmitted; actual requested
  and active sequences are observed separately. `src/main.rs::next_control_input`
  checks required objects every 100 ms between commands, not while an arbitrary
  effect retains the dispatcher.
- **Impact:** a nominal 100 ms polling interval is not a 100 ms stop/health bound.
  A socket acknowledgement cannot universally mean adopted science state, and
  timing out a client does not cancel a mutation already applied by the host.
- **Required decision:** either explicitly permit bounded busy intervals up to
  existing effect timeouts and expose observation age, or introduce asynchronous
  completion events under the same owner. Do not let another thread mutate the
  Runner to make stop appear immediate. Define maximum pending operations and
  retry/unknown-outcome semantics; never silently replay mutation after reconnect.
- **Validation:** stopped submission, running adoption, no-frame adoption timeout,
  disconnect after dispatch, repeated client request, concurrent health/stop and
  owner loss; response distinguishes requested versus active state and freshness.

### DEP-004 — User units cannot manufacture RT rights or correct worker placement

- **Severity:** high. **Confidence:** high. **Status:** deployment admission requirement.
- **Evidence:** active `RTC-ARCH-019` assigns loop scheduling/locking to PipeWire
  and thread placement to owner libraries. Installed `systemd.exec(5)` documents
  that user units cannot raise limits above the user manager's inherited hard
  limits. Current benchmark profiles separately configure process envelopes,
  loop CPUs/priorities and Julia pins.
- **Impact:** a unit containing LimitRTPRIO/LimitMEMLOCK is not proof those
  resources were granted. Setting whole-process FIFO could elevate control,
  compiler and runtime helper work beyond the intended workers.
- **Required remedy:** declare prerequisites and inspect effective limits,
  affinity and policies before ingress. Use process envelopes and library-owned
  thread scheduling; keep discovery/control on housekeeping. Do not silently
  alter host RT throttling, governor, system limits or permissions. Report
  degradation explicitly or reject a profile that requires unavailable rights.
  Avoid hardening directives that deny required RT scheduling or library access.
- **Validation:** foreground and user-unit environments with sufficient and
  insufficient rights; failures occur before ingress and report the exact unmet
  requirement. Thread snapshots cover owner helpers as well as named data loops.

### DEP-005 — Service dependency order does not define coherent session recovery

- **Severity:** high. **Confidence:** high. **Status:** contract decision required.
- **Evidence:** `src/live.rs::capture_required_external_objects` and
  `check_external_object_contracts` retain exact global/port identities and reject
  disappearance/replacement. `src/main.rs` uses stdin EOF as exit and lacks a
  deployment listener/service lifecycle. External objects remain externally owned.
- **Impact:** independently restarting a daemon/Julia owner can leave a live RTC
  in FAULT or attach new readiness to an obsolete session; ordinary service
  ordering alone cannot establish same-instance readiness.
- **Required remedy:** choose a coherent restart policy: safest first slice is
  dependency loss stops admission and fails the session; an explicit restart
  recreates/validates the full dependent set. Use service dependency propagation,
  finite startup/stop deadlines and owned-process cleanup. Do not restore
  RUNNING automatically from stale state. Preserve unrelated/external objects
  when RTC unloads; supervisor terminates only its own external owner processes.
- **Validation:** kill each process before/after readiness, peer replacement,
  port mutation, SIGTERM during update, stale socket, repeated start/stop and
  partial launch rollback. Foreground and service mode yield the same lifecycle.

### DEP-006 — Packaged profiles must name the actual maintained scientific graph

- **Severity:** medium. **Confidence:** high. **Status:** profile acceptance requirement.
- **Evidence:** `configs/revolt-classic-native-development.conf` declares the
  maintained HIL 277 × 376 reconstructor and integrate interface. The matched
  Classic benchmark uses a different 221-coordinate completion/clipping graph.
  Existing benchmark launchers separately compose row/full-frame schemas and
  actual FGN/JFG owners. The generic runner currently allowlists safe source and
  sink factories in `src/config/decode.rs`.
- **Impact:** relabeling a HIL fixture as the matched Classic graph would preserve
  filenames while changing the scientific law. Exporting a benchmark command
  without its graph/calibration/runtime dependencies would not be an installable
  package. Broadening factory admission casually could also admit physical output.
- **Required remedy:** profile matrix names Classic/Copper, FGN/JFG, full-frame/row
  and exact source/sink units/schemas. Reuse maintained generators and actual
  algorithms, with unchanged coefficients/feedback. Keep non-actuating endpoint
  admission explicit; add public endpoint capability only where needed. Export
  stable paths or recorded external prerequisites, not private temporary depots.
- **Validation:** all eight requested combinations export and load the expected
  contracts; compare graph/calibration hashes and numerical behavior with their
  maintained direct oracle. Row loss/reset/adoption and conditional publication
  remain host/library responsibilities with existing negative coverage retained.

## Minimal implementation slices and acceptance evidence

1. **Promote the small contract.** Update active scope/IDs and select the source
   hold/release, restart and response semantics above. Inventory executable,
   plugin, Julia environment, calibration and profile dependencies. Do not import
   the inactive archive.
2. **Extract shared control and load-only execution.** Typed parse/execute/reply,
   bounded request/payload preparation and one dispatcher. Add Unix listener and
   client with admission limits; preserve stdin as a front end. Test the bounds,
   errors and generation semantics without a service manager first.
3. **Export one complete foreground profile.** Private core, native graph, RTC,
   non-actuating source/sink; explicit readiness/placement and teardown. Prove
   no ingress before admission and dependency failure cleanup. Extend by replacing
   only the processing owner with the prepared external JFG owner.
4. **Install and wrap the same commands in user units.** Explicit prefix/runtime
   paths, user-owned sockets, prerequisite reporting, dependency propagation and
   stop deadlines. Verify unit syntax and a private user-service lifecycle;
   installation alone is not deployment verification.
5. **Complete the requested profile matrix.** Export/load and numerical checks
   for Classic/Copper × FGN/JFG × full-frame/row; record missing prerequisites as
   unsupported until resolved. Then add the future AOS/HIL graph through its
   existing external-source contract as separately scoped work.

A functional foreground test, a user-unit lifecycle test and a timing experiment
are different evidence. Prior CPU0-free results establish bounded benchmark
observations for their archived launcher; they do not qualify new service units.
Require fresh service placement and startup/failure evidence before claiming
operational deployment. Any later latency claim needs its own fixed-arrival
load, complete delivery/deadline accounting, control-load interference and
resource assumptions; no such measurement was performed in this review.

## Implementation checkpoint — independent source review

The primary has adjudicated active RTC-ARCH-020 and RTC-DEV-020 through
RTC-DEV-023. This checkpoint reviews the in-progress RTC implementation and
`JuliaFilterGraph.jl-deployment-owner/deployment/{run_island,startup}.jl`.
Exporter output and live package validation are not yet complete. No build,
live deployment or benchmark was run by this reviewer.

Observed improvements: explicit `--start-paused`; one typed command executor
shared by console/socket front ends; a sole Runner owner; bounded request and
parameter byte declarations; owner-only socket path admission and inode-aware
unlink; launcher instance directories and readiness markers; installed-prefix
lookup; process leader/worker placement inspection; coherent owned-process
teardown; and Julia preparation before connect, followed by reset/deactivation.
These source observations are not a final validation disposition.

DEP-001 and DEP-004 have substantive implementation paths, but source silence
and actual effective placement still require the planned live functional
checks. DEP-002 remains open while the primary repairs owner-response timeout
handling, absolute client deadlines and socket shutdown ordering. Specifically,
the reviewed seven-second reply timeout permits the worker to prepare another
request while a prior owner request remains pending; per-read timeouts do not
bound a slow-drip request; and joining the socket worker before Runner stop can
delay cleanup. These issues were independently identified by the primary and
are not claimed here as new discoveries. DEP-003 is further constrained by
DEP-009 below. DEP-005/006 require final package lifecycle/profile evidence.

### DEP-007 — Generated service loses the selected PipeWireAO prefix

- **Severity:** medium. **Confidence:** high. **Classification:** confirmed
  implementation defect at this checkpoint. **Disposition:** remediation requested.
- **Evidence:** `deployment/deploy.py::install` accepts `--pipewire-prefix` and
  validates the package against it. `deployment/pipewireao-rtc@.service.in`
  invokes `run` without that argument, whose parser defaults to `/opt/pipewireao`.
- **Impact:** foreground/install can select one runtime while its generated
  service chooses another or fails; RTC-DEV-023 foreground/service environment
  equivalence does not hold for a supported alternate prefix.
- **Remedy/validation:** render the selected absolute prefix into ExecStart with
  correct systemd escaping. Verify nondefault paths, spaces and percent signs,
  alongside the default prefix. No runtime selection should depend on which
  unrelated installation happens to exist at `/opt/pipewireao`.

### DEP-008 — Parameter path inspection does not make the subsequent open safe

- **Severity:** medium. **Confidence:** high. **Classification:** confirmed
  implementation race. **Disposition:** remediation requested.
- **Evidence:** `src/control.rs::prepare` performs `symlink_metadata`, requires
  a regular file, then calls blocking `File::open` before checking the opened
  descriptor. Replacement with a FIFO between those operations blocks before
  the second check; replacement with a symlink contradicts the stated no-symlink
  admission rule. Byte-limited reads do not address blocking open.
- **Impact:** the sole socket preparation worker can be trapped by a changed
  payload path, affecting further control and joined shutdown. Access is already
  owner-only; this is a bounded-operation/robustness finding, not a claim of a
  cross-user privilege escalation.
- **Remedy/validation:** open with no-follow/nonblocking descriptor flags, then
  inspect the actual descriptor before allocating/reading. Keep extent/byte
  checks. Exercise replacement by FIFO and symlink without hanging the test.
  Regular-file I/O on an unavailable filesystem remains a separate operational
  timeout limitation; do not describe a byte bound as a storage-latency bound.

### DEP-009 — Old equal generations can falsely certify a stopped update

- **Severity:** high. **Confidence:** high. **Classification:** confirmed semantic
  defect. **Disposition:** remediation requested before active-adoption claims.
- **Evidence:** `src/control.rs::Command::execute` for `PropertiesSet` dispatches
  the mutation, queries generations, and reports `active` when every observed
  active generation equals requested. `src/live.rs::update_properties` in the
  stopped case returns `Submitted` after a roundtrip; the old generations can
  still be equal while the new mutation awaits preparation/start.
- **Impact:** equality of old observations is incorrectly attributed to the new
  request, violating RTC-DEV-022's submission/adoption distinction.
- **Remedy/validation:** use the effect's observed adoption result or prove a
  requested-generation advance relative to this request's baseline. A stopped
  submission must not be called active from equality alone. Add a stopped
  update case starting with equal nonzero generations, then establish adoption
  after start through fresh host evidence. Preserve requested/active fields
  even when the command outcome remains submitted/unknown.

### DEP-010 — Rust control client does not check echoed request identity

- **Severity:** medium. **Confidence:** high. **Classification:** confirmed
  protocol validation omission. **Disposition:** remediation requested.
- **Evidence:** `src/control_socket.rs::send_request` checks response version
  but returns a response with an arbitrary `id`; `deployment/deploy.py::control`
  already validates both version and the generated request ID.
- **Impact:** the two supported clients implement different response identity
  guarantees. A malformed/mismatched response can be attributed to the wrong
  operation by the Rust client.
- **Remedy/validation:** retain the sent ID and reject absent/different echoed
  IDs. Use an offline fake peer returning matching, missing and different IDs.
  No automatic mutation retry should result from the rejection.

### DEP-011 — Generic Julia warmup success is not proof of terminal publication

- **Severity:** medium. **Confidence:** high for the source condition; actual
  profile failure is unestablished. **Classification:** validation gap, not a
  demonstrated scientific defect. **Disposition:** profile checks required.
- **Evidence:** `deployment/startup.jl::prewarm_cpu_node` accepts a terminal
  result when every output is `published || conditional`. With entirely
  conditional row-graph outputs, an all-false result passes. It then copies
  feedback scratch into the next warm sample regardless of publication.
- **Analysis:** suppressing an output can be valid for a generic conditional
  graph, so a universal “all outputs must publish” change would be unjustified.
  However the current check cannot establish that the maintained Classic/Copper
  terminal demand and feedback path executed. The reviewed row test covers a
  smaller fixture, block count and reset, not all packaged scientific profiles.
- **Required validation:** for the actual Classic/Copper profiles, assert expected
  terminal demand/feedback publication during valid full-frame/row samples and
  compare the first real sample after warm/reset with an unwarmed direct oracle.
  Include retained feedback, nondefault calibrated parameters and both samples
  used by warmup. Keep graph-generic conditional semantics unchanged unless
  evidence supports a narrower contract.

Julia startup metadata currently derives block count from the declared input
rate and detector-row offset from `block * shape[1]`. The warmup calls the same
admitted graph path and finally resets/deactivates, restores `owner.warmed`, and
clears synthetic input/output storage. These mechanisms are appropriate source
foundations; only the required fixture checks can establish complete numerical
reset and specialization coverage for the installed scientific profiles.


## Final source checkpoint — 2026-10-01

This independent pass inspected the pending RTC deployment worktree at
`7122d1c` and the generic Julia owner worktree at `4a75677`, including their
uncommitted changes. It did not run production processes or benchmarks. The
findings below are source-confirmed; live deployment and user-service evidence
remain separate validation obligations.

The DEP-002 socket remedies are present: one worker retains the admitted slot
until actual owner acknowledgement, including after a client response timeout;
read/write/connect budgets use monotonic deadlines; shutdown requests stop the
listener before Runner cleanup and join the worker afterward. Parameter-file
I/O is still ordinary regular-file I/O and is not a bounded filesystem-latency
claim. The supervisor's finite process-termination fallback remains necessary.

DEP-007 through DEP-010 have source-level remedies: the generated unit includes
the selected absolute PipeWireAO prefix; parameter open uses `O_NOFOLLOW` and
`O_NONBLOCK` plus descriptor identity/extent checks; property adoption requires
a new requested generation observed active while running; and the Rust client
checks echoed request identity. Focused regression tests are present. This pass
did not independently execute those tests.

DEP-011 now has a public `FilterGraphPipeWire.prepare!` contract with explicit
required terminal outputs. The exporter requests both demanded and retained
feedback outputs for all maintained Julia profiles. Preparation resets and
deactivates the owner in `finally`, restores its warmup flag, and clears
synthetic storage. The startup adapter imports only explicitly exported concrete
Algorithm declarations. This is appropriate source-level remediation; actual
profile/oracle evidence must be retained separately.

The optional FITS `api.fits.layout=row-major` change reverses the two image
axis declarations while retaining width-contiguous bytes. Default image
column-major behavior, vector/row-block row-major behavior, and direct CFITSIO
output remain unchanged in the reviewed source. Non-square descriptor and
unchanged-pixel checks are present; no additional copy or transpose was added.

### DEP-012 — Invalid scalar-property targets still fault a healthy session

- **Severity:** high. **Confidence:** high. **Classification:** confirmed
  control-path defect. **Disposition:** remediated in the subsequent verification checkpoint below.
- **Evidence:** `src/control.rs::Command::execute(PropertiesSet)` dispatches
  `LifecycleEvent::UpdateProperties` without prevalidating the target graph or
  property declarations. `src/live.rs::update_properties` rejects an unknown
  controlled graph or incompatible property declaration inside the effect.
  `src/lifecycle.rs::ready` and `running` transition to Fault on an unsuccessful
  UpdateProperties completion. `src/main.rs::control_session` then observes
  Fault and exits. For example, `property nonexistent node:gain float 0.1`
  is syntactically accepted and follows this path from a healthy Ready session.
- **Impact:** an operator target/name/type error terminates a healthy deployment
  instead of rejecting only the request, contrary to RTC-DEV-022. The new
  parameter prevalidation correctly addresses pending/incompatible parameter
  requests but does not protect the scalar transaction path.
- **Remedy:** validate graph identity, property declaration, mutability and
  value compatibility on the serialized owner before lifecycle dispatch, using
  the same authoritative checks as the effect. Preserve fault handling for
  genuine owner/transport failures after an admitted operation.
- **Validation:** from Ready and Running, reject an unknown graph, unknown
  property and incompatible scalar type while preserving lifecycle, topology
  and subsequent valid controls. Establish fail-before/pass-after evidence.

### DEP-013 — Owner shutdown can race RTC ingress revocation

- **Severity:** high. **Confidence:** high. **Classification:** confirmed
  lifecycle ordering gap. **Disposition:** remediated in the subsequent verification checkpoint below.
- **Evidence:** `deployment/deploy.py::Deployment.stop` sends `quit`, then
  immediately creates external-owner quit markers before waiting for the RTC
  process. In `src/control.rs`, Quit reports only that shutdown is requested.
  `src/main.rs::control_session` enqueues this response before returning to
  `run`, which subsequently stops and unloads the Runner. No acknowledgement
  or wait orders source shutdown before the Julia owner sees its quit marker.
- **Impact:** an external scientific owner can close while ingress remains
  admitted in RTC, including when stop/unload is delayed. The required
  ingress-before-consumer teardown ordering in RTC-DEV-021 is not established
  by the quit-request acknowledgement.
- **Remedy:** establish successful session stop/Ready or completed RTC teardown
  before requesting external-owner termination. If RTC cannot stop admission,
  the bounded fallback must revoke the owned source/core before tearing down
  its consumers. Keep cleanup of all owned processes and preserve unrelated
  processes.
- **Validation:** delay RTC stop completion and verify owner quit markers remain
  absent until ingress is stopped. Cover RTC failure, unresponsive control,
  SIGTERM during an effect, ordinary foreground shutdown and user-unit stop.


### Retained evidence inspected in this pass

The offline record
`~/.cache/rtc-deployment-functional-20261001/jfg-warm-reset-provenance.json`
reports 332 assertions over Classic/Copper × complete-frame/row Julia profiles,
with two real samples per profile after public owner preparation and zero
maximum difference for demanded and feedback values versus fresh direct graphs.
This reviewer read the oracle script and verified its hash, each profile's
source/graph hash, and the four recorded implementation hashes against the
current owner source and Manifest. The oracle uses direct Graph calls after
`prepare!`; retained feedback-slot reset is checked by the separate owner unit
test. It establishes the scoped numerical reset result, not native transport,
service admission, resource bounds or a new latency result. DEP-011's specific
profile-validation gap is addressed within that scope.

The only live profile record present when inspected was
`~/.cache/rtc-deployment-functional-20261001/evidence/classic-fgn-frame.json`:
seven discarded commands, held-before-admission observations, scalar submission,
parameter submission/generation observations, reset and cleanup are recorded.
This is one functional profile, not completion of the eight-profile matrix.
The primary reports the Classic FGN row path and JFG placement expectations
remain under investigation. No live failure mechanism is promoted to a
confirmed root cause by this review.


## Remediation verification checkpoint — 2026-10-01

This pass reviewed current RTC source at base `7122d1c` with pending changes,
Julia owner commit `116cdb4`, FITS source at base `288bbeb` with pending layout
and row-handoff changes, and the public FITS header at base `34c7a04`.
Only this review document was changed. No production playback, benchmark or
hardware test was run by the reviewer.

**DEP-012 is remediated in source.** `Command::execute(PropertiesSet)` now
calls `LiveGraphAdapter::validate_property_update` before lifecycle dispatch.
The effect uses that same validation: controlled graph identity, qualified
property names, declaration, writability and exact scalar types. Invalid input
cannot enter the effect-failure transition through the identified path.
The live regression harness checks invalid graph/name/type and mixed
transactions in Ready and Running, unchanged observations, valid subsequent
updates, and rejection of an initially pending parameter. Its source also
checks group stop/start and stopped submission followed by fresh adoption.
The primary reports the focused live harness passed; this reviewer inspected
its assertions without rerunning the live test.

**DEP-013 is remediated in source.** `Deployment.stop` requests session stop
when Running, records a Ready acknowledgement, and waits for RTC teardown
before creating consumer quit markers. If ingress stop was not acknowledged,
it terminates the owned source/core first. The finite process-termination
helper retains TERM/KILL fallback. Ordering tests cover acknowledged stop and
unconfirmed/Fault fallback. The reviewed service records additionally show
normal external Julia owner shutdown and native dependency-failure cleanup.
An unkillable OS process remains outside an application-level completion
guarantee; errors are retained and systemd supplies the final service bound.

### FITS row handoff contract and evidence

The reviewed implementation obeys the public SPA buffer-loan boundary:
a published output remains unavailable for reuse until its identity returns
through the IO area and `process` recycles it. `ready` announces processing
readiness; it does not prove downstream processing completed. These semantics
are documented in the [SPA node methods](https://docs.pipewire.org/structspa__node__methods.html)
and [SPA callbacks](https://docs.pipewire.org/structspa__node__callbacks.html),
and in the repository's public `spa/node/node.h` and `spa/node/io.h` headers.

`process_row_block` now reports an existing HAVE_DATA loan before inspecting
cadence. The timed row path records one outstanding buffer identity before
calling ready, disarms further timer publication while that loan remains out,
and rearms the original cadence deadline after the matching return. The host
process pass does not publish a second row. This uses public IO and loop
interfaces, adds no allocation or logging on the row path, and reads no
PipeWire-private activation state. Finite completion is published only after
the terminal row's matching return. Existing cadence skip/actual-pool-exhaustion
behavior remains; this is not a lossless fixed-arrival or latency claim.

The retained report is
`pipewireao-spa-plugin-fits-rtc-layout/build/row-handoff/REPORT.md`.
This reviewer read the fail-before regression log: the original handoff fails
`spa_node_process(node) == SPA_STATUS_HAVE_DATA` before the next deadline.
The new tests cover pending loans across deadlines, NEED_DATA without a returned
identity, host process re-entry, terminal return and restart. Both installed
source-to-discard logs (`same-107592` and `separate-107592`) report 224 blocks,
1,734,656 bytes, zero errors and 224 process calls for seven frames. The installed
FITS library hash was independently checked as
`3f3fb042201afb2cf646fd76a468103d8f57609e0630eef065b332fe03e14e2a`.
These results establish the tested isolated handoff correction; they do not
establish correctness of every scientific graph or explain remaining losses.

### Deployment evidence and remaining acceptance gates

Under `~/.cache/rtc-deployment-functional-20261001/evidence/`, this reviewer
inspected all four `*-frame.json` records: Classic FGN/JFG each have seven
commands, Copper FGN/JFG each have four, and all report clean shutdown.
The later Copper FGN/JFG row records each report four commands and cleanup.
Each record retains held-before-admission checks, effective placement and
control observations. These are finite functional checks, not timing or
physical-system qualification.

`systemd.json` retains two separate successful native launch instances,
a native dependency-death case with failed service status and complete owned
cleanup, and successful Julia service stop; each observed four commands.
This supports the exercised user-service lifecycle cases. It does not imply
that every failure mode or every profile has been exercised under systemd.

The Classic FGN row scientific deployment still has a reported five-of-seven
command result at 10 Hz with 2 ms readout. Classic row acceptance and the full
eight-profile matrix therefore remain open at this checkpoint. The isolated
FITS source fix must not be presented as closure of that remaining graph-path
failure. No further production change is recommended without discriminating
input/publication/terminal-output evidence for the failing path.


## Parameter-route adjudication — 2026-10-01

The proposed narrow remediation separates declared live-update topology from
optional startup parameter publication. It does not change scientific owner
adoption semantics, the progressive scheduler, or the public ndarray interface.
This is an accepted design direction, not completed validation of its pending
implementation.

### DEP-014 — Preloaded profiles redundantly submit their initial reconstructor

- **Severity:** high for exact progressive replay. **Confidence:** high for
  duplicate submission; native first-frame attribution still requires the
  controlled replay below. **Classification:** confirmed redundant startup
  transaction, with a partially established causal effect.
- **Evidence:** `deployment/export.py::native_graph` binds the reconstructor
  through `pipewireao.startup-parameter`; `julia_owner` supplies the same file
  through the generic owner's startup `--parameter` option. The exported RTC
  session also supplies that reconstructor in `parameters`. RTC queues this
  initial value during realization and triggers pending publishers after graph
  start. The live route map currently derives from those initial-map keys,
  forcing a submission merely to retain a later-update route.
- **Owner semantics:** Julia's public `replace_parameters!` documentation and
  `JuliaFilterGraph/src/parameters.jl::_adopt_parameter_transaction!` explicitly
  abandon in-flight publication units before adopting prepared plans. The
  adapter calls that adoption function for a pending parameter transaction.
  There is no identical-byte no-op guarantee. An update-associated missing
  progressive command therefore does not alone demonstrate transport loss.
- **Observed discriminator:** the retained bounded diagnostics report all 224
  source rows published and returned, no source skips/pool exhaustion, and the
  terminal sequence delivered. Native plain playback lacks sequence 0; the
  run with control changes lacks 0 and 2. This excludes a missing terminal
  source row as the explanation in those runs. It does not by itself prove
  that every missing output had the same cause.
- **Remedy:** derive the runtime route map from validated declared publisher
  links. Treat `parameters` as an optional subset of startup submissions.
  Preloaded exported profiles omit those duplicate submissions while retaining
  the exact publisher/graph route and installed file reference for later
  controls. Explicit startup publications remain supported for other profiles.
- **Required causal validation:** replay the same loaded native calibration and
  source without operator mutation, changing only duplicate initial submission.
  Compare command identities and numerical values where captured, including
  sequence 0. The pending route change must pass this before the native startup
  loss is described as resolved.

The route contract must apply independently of the initial-value map:

1. Every runtime parameter publisher has exactly one declared output route.
2. Its target is a graph input explicitly marked as a parameter; source and
   target element type, shape and schema match exactly.
3. The link is passive. No publisher fanout, unlinked publisher or multiple
   publishers targeting one input is admitted.
4. Every supplied initial-file entry resolves to one of these routes and keeps
   the existing path/file checks. Absence of an initial entry queues no payload;
   it neither removes the route nor manufactures an initial scientific value.
5. General link validation and sparse-parameter passive rules must agree even
   when the processing graph is outside an execution group. Existing profiles
   with explicit initial submissions retain their behavior.

Scientific initialization remains the graph owner's responsibility. The exporter
may omit initial submission because its maintained native/Julia profiles have
an evidenced preload path; a generic live-only route does not prove a graph
has valid calibration.

### Qualification boundaries

Exact replay must run without mutating properties or parameters during ingress
and retain its full count/identity oracle. A separate control-adoption check
must demonstrate requested-generation advance, eventual active adoption and
successful processing of subsequent complete frames. It may account for an
owner-defined abandoned in-flight unit; it must not relax into permitting
arbitrary unexplained loss. A mutation run is not a seven-command exact replay
if the owner legitimately abandons a partial frame.

The busy/rejection harness should explicitly queue a startup parameter in its
own rendered fixture. It must not rely on redundant submission in every
preloaded production profile to create the pending condition. Removing that
redundancy is compatible with retaining the existing busy-publication test and
the scalar invalid-request tests. No change to legitimate owner adoption or
upstream transport behavior is recommended by this adjudication.


## Final deployment verification — 2026-10-01

This checkpoint reviews RTC commit `50dc370`, Julia owner commit `116cdb4`,
and the previously reviewed installed FITS handoff correction. The reviewer
read source and retained evidence and independently checked artifact hashes;
no production source was edited and no replay, benchmark or test suite was
run by this reviewer. Only this document was changed.

### Route and startup remediation

**DEP-014 is remediated for the tested startup delivery failure.**
`src/config.rs:829` validates every runtime publisher independently of initial
files: exactly one passive link, a graph parameter input target and no duplicate
publisher target. `validate_initial_parameters` accepts an optional subset and
retains file-reference and scientific-contract checks for provided entries.
General link admission checks direction, element type, shape, schema, rate and
single-producer ownership. Its passive rule at `src/config.rs:1826` includes
runtime publishers even when the target graph is outside an execution group.
`src/live.rs:824` builds live routes from that validated topology. A missing
initial entry no longer removes later replacement capability.

`deployment/export.py:331` leaves the initial map empty because both maintained
owners preload the calibrated reconstructor. Their runtime source, passive
link and installed parameter-file reference remain. No owner adoption or
progressive abandonment semantics were changed. Configuration tests cover
empty and partial initial maps, invalid topology/contracts and the ungrouped
application-owned graph case. The focused live-route test checks processing
after startup and a fresh adopted parameter generation after later replacement
with an empty initial map. The primary reports 89 Rust tests passed, three
ignored, that live test explicitly passed, Clippy passed and 38 Python tests
passed including eight actual exports. These suite results are reported
verification; their relevant assertions were independently inspected.

The retained native Classic logs
`~/.cache/rtc-deployment-functional-20261001/classic-fgn-row-plain.log` and
`classic-fgn-row-noinitial.log` show respectively six and seven commands.
The primary records the same source cadence, calibration and science, with
duplicate initial submission removed for the latter run. The earlier bounded
discard trace in the core worktree's `build/row-discard/plain.log` retains
sequences 1 through 6. Together with the confirmed duplicate transaction and
owner adoption contract, this supports the startup remediation. The after-run
logs record counts, not output identities or numerical values; they do not
establish live numerical equivalence or a universal losslessness guarantee.

A subsequent bounded identity probe is retained in the core worktree's
`build/row-discard/latest-plain.log` and `latest-provenance.json`. The reviewer
read the log: the final Classic FGN row path delivers Header sequences
`[0, 1, 2, 3, 4, 5, 6]` exactly once, with all 224 source blocks published and
returned, zero source skips/pool shortages and terminal completion. The
provenance records unchanged calibration, graph, science library and FITS input
hashes versus the earlier failing private profile. Removing the initial-map
entry is the only semantic session change; the RTC executable and admission
policy also changed. This verifies the observed identity improvement without
attributing it to an isolated binary instruction or adding a numerical claim.

### Final installed evidence

The reviewer independently checked all declared artifact hashes in the eight
installed `~/.config/pipewireao-rtc/revolt-*` packages: zero mismatches across
19 artifacts per Classic FGN package, 150 per Classic JFG package, 15 per Copper
FGN package and 144 per Copper JFG package. Every installed session has an empty
initial parameter map. All eight bundled RTC executables match SHA-256
`1a32b6f6b86e81fb942c87de7f8f870a42ccbef4ed27ad208fce9a9db985f78c`.

Final records under `~/.cache/rtc-deployment-functional-20261001/evidence/`:

| Record | Commands | Control mutation during check | Shutdown |
| --- | ---: | --- | --- |
| `classic-fgn-frame.json` | 7 | Yes | Clean |
| `classic-fgn-row.json` | 7 | No | Clean |
| `classic-jfg-frame.json` | 7 | Yes | Clean |
| `classic-jfg-row.json` | 7 | No | Clean |
| `copper-fgn-frame.json` | 4 | Yes | Clean |
| `copper-fgn-row.json` | 4 | No | Clean |
| `copper-jfg-frame.json` | 4 | Yes | Clean |
| `copper-jfg-row.json` | 4 | No | Clean |

Each has three pre-admission Ready observations with zero commands, effective
placement records, matching requested/active property and parameter generations,
reset, invalid-command survival and clean owned-process shutdown. The frame
checks include scalar and matrix submissions; row checks keep the prepared
graph unchanged. This closes the eight-profile functional command-count gate,
including the previously failing Classic row profiles. The oracle counts
discarded commands; it does not compare live command vectors or prove identities
across the matrix. The separate Classic FGN row probe above checks identities
for that profile. The earlier public-prepare offline oracle remains the separate
332-assertion numerical reset evidence.

The existing `systemd.json` evidence supports the previously described two
native launches, native dependency-failure cleanup and Julia stop. It predates
the final empty-initial-map matrix and is not represented as a fresh service
rerun of all eight final profiles. The property harness now explicitly queues
a stopped parameter in live-update-only fixtures before checking pending-value
rejection, preserving DEP-012 coverage without recreating redundant startup
publication in production profiles. DEP-013's stop/Ready acknowledgement and
owned-core fallback ordering remain as reviewed above.

**Remaining limits:** progressive parameter updates intentionally may abandon
an in-flight unit. The immutable row matrix is not a row-update recovery test;
generation adoption alone is not proof of a later correct command vector.
No latency, sustained-rate, overload, physical AOS/HIL or HEART qualification
is established here. Within this deployment increment and these limits, this
pass found no further confirmed source defect requiring remediation.


### Final evidence addendum — 2026-10-01

The reviewer inspected the subsequent evidence below. RTC production source
remains `50dc370`; the pending changes inspected are the focused live-route
test and README command arguments. No further source defect was confirmed.

- **DEP-014 causal discriminator:** the core worktree's
  `build/row-discard/duplicate-initial.log`, `duplicate-initial-diff.json` and
  report now compare the same final RTC executable, diagnostics, science and
  FITS data. Restoring only the duplicate initial mapping changes delivered
  Header IDs from `[0, 1, 2, 3, 4, 5, 6]` to `[1, 2, 3, 4, 5, 6]`; both sources
  publish and return all 224 blocks without skips or shortages. The profile
  file changes are the session mapping and its required artifact hash.
  This establishes duplicate initial publication as sufficient to reproduce
  initial-command suppression in this configuration. It does not identify an
  internal suppressing stage or establish numerical equivalence.
- **Post-adoption progress:** `tests/live_parameter_routes.rs` now takes the
  baseline generation after Start and observed output, before replacement.
  This prevents the owner's startup preload from satisfying a replacement
  assertion against the earlier zero baseline. After fresh adoption it takes
  a new output-count baseline and requires an increase within five seconds,
  checking that requested and active generations stay at the adopted value
  during polling. The retained `/tmp/rtc-parameter-recovery-frame-20261001-after.log`
  and `/tmp/rtc-parameter-recovery-row-20261001-after.log` pass with generation 2
  and count advances 4→5 and 2→3. This adds functional progress after replacement
  for the tested Classic FGN frame/row profiles; vector correctness and exact
  delivery through mutation remain outside this assertion.
- **Fresh controls and services:** `classic-fgn-controls.json` and
  `classic-jfg-row-controls.json` each record seven rejected cases in Ready and
  seven in Running with state preserved, explicit stopped pending-value
  setup/rejection, adopted gain/pole updates, group stop/start, reset and clean
  shutdown. The refreshed `systemd.json` records two native launches, native
  dependency-failure cleanup and Julia stop, each with four commands and exact
  cleanup; the final recorded MainPID is zero in each case. These replace the
  historical service records described above and support the exercised cases
  on the current installation. They do not constitute an eight-profile service
  matrix. The README example now supplies the harness's required gain and pole.

DEP-012, DEP-013 and DEP-014 retain their remediated dispositions. The isolated
startup comparison and post-adoption progress close the corresponding evidence
gaps from the preceding checkpoint. No timing or hardware claim is added.
