# PipeWireAO RTC audit and reconstruction contract

Status: proposed normative companion contract

Review date: 2026-08-31

## Authority and applicability

This document defines auditable progression, causal event identity, terminal
disposition, durability isolation, run reconstruction, and safe replay for the
[PipeWireAO RTC system architecture](architecture.md). The
[operational architecture](operations.md) owns recorder topology
and storage layout. The
[time, causality, and performance contract](time-and-performance.md)
owns clock domains, causal ordering, replay pacing, and timing evidence. The
[scientific data and command contract](scientific-data-and-command-contracts.md)
owns DM command stages and outcomes. RTC-OPS-004 in the
[operational architecture](operations.md) defines the RTC authority epoch used
for correlation and stale-event rejection and RTC-OPS-005 defines run
allocation and closure. The
[camera-session contract](camera-sessions.md) defines its camera-source identity
branches. RTC-EXEC-001 through RTC-EXEC-005 in the operational architecture
define execution-composite identity, preparation, activation, control, and
failure; this document owns their retained provenance and reconstruction
consequences.

Applicability follows RTC-OPS-006. The complete contract applies to protected
operational actions, selected durable recording, reconstructable runs, and
safe replay. A `development` runner may emit diagnostics or a best-effort event
log without claiming this contract. Such a log is not a reconstructable run and
does not require the recorder, catalog, authority epoch, recovery owner, or
durability machinery merely to run a simulated graph.

PipeWire object and parameter acknowledgements are observations at generic API
boundaries. They do not replace the RTC target's domain-specific admission,
activation, device-result, or durability evidence.

Uppercase requirement terms use the meanings defined by BCP 14 (RFC 2119 and
RFC 8174). Lowercase forms are ordinary prose.

An **RTC startup-attempt identity** is the nonreused service-invocation UUID
assigned by the operating-system service manager before it launches an RTC
application process. In the initial systemd profile this is the invocation ID,
not a second UUID beside it; another service manager supplies an equivalent
one-to-one invocation identity. It identifies one startup attempt and is
available even if the application cannot allocate an RTC authority epoch. It is
correlation evidence, not lifecycle authority. For a pre-epoch event it also
serves as the correlation identity unless that event has a narrower operation
identity. It is outside the camera-session generation scope graph and links the
startup attempt to epoch allocation. UUID representation follows RTC-OPS-004.

An **RTC-attributed audit event** is emitted by the RTC application, by the
service manager while performing that application's launch or admission, or by
another component after that producer has received and retained an explicit
binding to an identified RTC operation. A source observation that has no such
binding remains independently authored even when an RTC request happened
earlier. An
**independently authored component event** reports daemon, device, plugin, or
supervision state without a known RTC launch or operation association. Event
authorship and RTC association are separate: an associated component event
retains its component author identity rather than treating the RTC as its
author.

An **event-author identity** is a fresh UUIDv4 for one audit-producer
incarnation, allocated from the operating system's cryptographically secure
random source before the producer's first event. The audit binding owner MUST
reject a collision with a retained author identity; allocation or collision-
check failure prevents emission rather than reusing an identity. It changes
before that producer's sequence can restart and uses the canonical UUID
representation defined by RTC-OPS-004. The physical device, process,
connection, or service-invocation identity remains separate author context; it
does not replace the event-author identity.

A **request identity** is a fresh, nonreused UUIDv4 allocated by the requester
before first submission. Delivery retry of the identical semantic request keeps
the identity; a changed payload or a new attempt uses a new one. A receiver MUST
reduce a duplicate idempotently or return the retained result and MUST NOT apply
the request again. An **operation identity** is a fresh, nonreused UUIDv4
allocated by the accepting owner before it acknowledges acceptance or starts an
external effect. The owner MUST publish the request-to-operation binding; status
retry keeps both identities. A contract MAY use one request identity as both
only when that owner explicitly adopts it and preserves the same uniqueness and
idempotence rules. A **correlation identity** is a fresh, nonreused UUIDv4 that
an initiator MAY allocate before the first member to group several requests,
operations, or events. It remains stable for that group but does not replace any
member identity, establish order, or confer authority. These UUIDs use the
RTC-OPS-004 representation.

Every identified protected request also belongs to the complete parent scope
defined by its operation family, such as the RTC startup attempt, authority
epoch and run, web-client session, camera reconciliation key, or direct-
engineering adapter connection. A receiver MUST declare finite in-flight and
terminal-idempotence capacities and the retention or acknowledgement rule for
that scope. The idempotence key MUST contain the complete parent scope and
request identity; a matching request UUID beneath another parent is not the
same request. Each operation family MUST define a versioned canonical request
encoding and collision-resistant digest algorithm, including the treatment of
absent and default fields, so an identical semantic retry has one digest and a
changed payload cannot be accepted as that retry. Before accepting a request
or starting its effect, the receiver MUST reserve both an operation/result slot
and an idempotence entry containing at least that complete key, canonical-
encoding version, and payload digest. Capacity exhaustion MUST reject the new
request before an effect; it MUST NOT evict an unresolved or still-retriable
entry to make room. Reuse of a retained key with a different encoding version
or digest MUST be rejected visibly without an effect.

A receiver MAY compact an acknowledged terminal entry into a bounded tombstone
that still detects identity reuse with a changed payload. It MAY retire that
tombstone only after the parent scope is terminal or an operation-specific
ordered acknowledgement fence proves that delivery can no longer recur. A
later message under a retired parent scope is stale and MUST NOT be applied.
If idempotence state is lost or its retained range is uncertain, the receiver
MUST reject further effectful requests under that parent scope and require the
declared endpoint reset, reconnection, or new parent identity; it MUST NOT treat
an unknown UUID as proof of a new request. RTC-RECORD-001 bounds durable
run-scoped retention, and an admitted maximum request count or earlier run stop
MUST keep that retention finite.

## Audit and command progression

### RTC-AUDIT-001 — Acceptance is not application

Every protected lifecycle, deployment, property, parameter, artifact, and DM
operation MUST distinguish target admission from the later boundary at which
the requested state becomes authoritative. Submission by a client or return
from a generic PipeWire parameter call MUST NOT be reported as application.

Each operation family MUST define its own valid progression. Examples include:

| Operation | Required distinguishable stages |
| --- | --- |
| Lifecycle target | requested, accepted or rejected, observed transition result |
| Deployment | requested, resolved, prepared, admitted or rejected, active |
| Scalar property or ndarray parameter | requested, prepared, committed, active or rejected |
| DM correction | proposed, requested physical, demanded, submitted, device result |
| DM safety intervention | authority absent, revoked, or expired; fail-safe selected; submitted; device result |
| Recorder durability | received, appended, durable, indexed, sealed or lost |

Verification intent (informative): delay and fail every stage independently;
verify that clients and the run record never advance to a later stage from an
earlier acknowledgement.

### RTC-AUDIT-002 — Causal audit identity

Before launching an RTC application, the operating-system service manager MUST
assign a fresh RTC startup-attempt identity and make it available to every audit
producer acting for that startup attempt.

Before the RTC process receives the RTC-OPS-002 guard or allocates an authority
epoch, the service-manager deployment—the manager and its configured non-
authoritative startup-audit helper, if one is required—MUST reserve the bounded
audit capacity required by RTC-RECORD-001 and durably open a startup-attempt
record that contains that
identity, the intended service unit and executable, its own event-author
identity, and the requested launch cause. The process MAY start with the read-
only discovery permission allowed by RTC-OPS-002; failure to open the record
MUST prevent authoritative admission and epoch allocation and MUST terminate
or retain that process as read-only. The service-manager deployment owns pre-
run terminalization. A configured helper MUST run outside the guarded RTC
service unit, MUST use its own event-author identity, and MUST NOT receive an
RTC-authoritative PipeWire connection or protected mutation capability. It is
an audit writer, not another RTC control holder.

The service-manager deployment MUST append the epoch- and run-allocation
bindings that it observes, or seal a terminal startup failure, process-loss
result, or explicit audit-loss range. On service-manager restart or re-
execution, it MUST
discover every unsealed startup-attempt record before admitting another
authoritative RTC, reconcile it with authenticated control-group and
RTC-OPS-002 guard evidence, and append a new-author recovery result without
rewriting or impersonating its prior event author. An uncertain attempt remains
visibly unsealed and contributes to the fail-closed replacement decision.

Every audit event MUST identify its event author and author-scoped sequence,
event family, stable target, and every correctness-relevant immediate
predecessor or cause required by that event family's schema. A multi-cause event
MUST carry a canonical finite predecessor set or an immutable bounded evidence-
set reference; the schema MUST declare its fan-in bound and missing-member
behavior. It MUST carry a correlation or operation identity when the event
belongs to such an operation. Every timestamp it carries MUST identify its time
domain and measurement point under RTC-TIME-001. It MUST carry semantic event
time when time is an explicit input to the authoritative behavior, and
otherwise MUST represent semantic event time as absent rather than fabricate it
from recorder arrival or wall-clock proximity. The event-author identity MUST
identify one producer incarnation and MUST NOT be reused. Its sequence MUST be
unsigned 64-bit value that starts at one, increments without wrap, and is not
reset until a new event-author identity is published. Before exhaustion, the
producer MUST publish a new event-author identity or stop emission with a
visible failure; it MUST NOT wrap. The pair of event-author identity and author-
scoped sequence is the event identity used for idempotence.

An RTC-attributed audit event as retained by the audit system MUST carry its RTC
startup-attempt identity and every allocated component of its applicable
identity key without omitting a parent, or MUST resolve them through an
immutable retained binding from the event's operation identity. Every
RTC-attributed event
within an allocated RTC authority epoch MUST therefore identify that epoch. A
pre-epoch RTC-attributed event MUST explicitly mark the epoch absent and MUST
NOT fabricate one. The successful allocation event MUST carry both identities
and causally bind the startup attempt to the new epoch; an allocation-failure
event MUST carry the startup-attempt identity and terminal failure reason.
An RTC-attributed event within an allocated run MUST likewise identify its
RTC-OPS-005 run identity directly or through the immutable operation binding.
An event before run allocation or between closed runs MUST mark run identity
absent; the run-allocation event binds the startup attempt, authority epoch,
and new run. An event from a prior or recovered run MUST NOT be associated with
a later run merely because the RTC definition, source process, or deployment
content is unchanged.
The audit catalog MUST retain the pre-epoch chain, or an explicit identified
loss range under RTC-AUDIT-004, even when the attempt never allocates an epoch
or run. A successful run MUST reference its startup-attempt record; a failed
attempt MUST retain a terminal startup record without fabricating a run identity.

An independently authored component event MUST retain the component's own
process, connection, device, or supervision identity as applicable and MUST NOT
fabricate an RTC startup-attempt identity or authority epoch. It MAY carry an
explicit startup-attempt or epoch association only when the producer has
observed a defined causal or correlation link; that association MUST NOT replace
the component author identity. Acquisition-derived events MUST carry or resolve
to their acquisition identity.

Recorder arrival order and wall-clock proximity MUST NOT create a causal edge.
Repeated observation of the same identified event MUST be idempotent for
reducers, indexes, and replay tools.

Verification intent (informative): inject missing and reused startup-attempt
identities, fail epoch allocation, then reorder, duplicate, and delay pre-epoch,
allocation, and in-epoch event publication across RTC restart. Interleave
daemon, device, and supervision events before, between, and after RTC launch
attempts, including one event with no semantic event time and one event during
clock-observation failure. Reject an invalid RTC attribution; retain independent
component authorship without inventing an RTC association; exercise a bounded
multi-predecessor event with a missing and reordered member; and reconstruct each admitted
startup attempt, its terminal allocation failure or unique successor epoch,
later progression, and explicit gaps without a fabricated epoch. Reset and
exhaust an author sequence, repeat a child sequence under a new author identity,
and verify that only the complete event identity is deduplicated. Crash before
run allocation and reconstruct the terminal or explicitly incomplete attempt
from the startup-attempt catalog alone. Emit pre-run, in-run, between-run, and
late prior-run events beneath one epoch and reject every fabricated or stale
run association. Duplicate delivery of one request before
and after acceptance and verify one effect and one stable operation binding;
reuse its identity with a changed payload and reject it. Exhaust in-flight,
terminal-result, and tombstone capacity; retry before and after acknowledgement
and parent-scope retirement; then lose a portion of the idempotence state.
Verify rejection before effect, compact duplicate detection, stale-parent
rejection, and fail-closed reset instead of replay. Fail startup-record
reservation and creation, then restart or re-execute the service manager before
launch, after read-only process launch, after epoch allocation, and after run
allocation; verify no unrecorded authoritative admission and one recovered,
terminal, or visibly unsealed startup-attempt chain before replacement
admission.

### RTC-AUDIT-003 — Terminal disposition

While it retains authority for an accepted protected operation, the owner MUST
produce one terminal disposition: applied, active, rejected, expired, aborted,
held, failed, indeterminate, or another operation-specific terminal result
defined by its schema. Cancellation, orderly shutdown, fault handling, or
controller disconnect MUST transfer or terminate every retained operation
rather than silently forget it.

When an RTC authority epoch is retired, the owner or recovery owner MUST do one
of the following for every protected operation retained under that epoch:
produce its terminal disposition; transfer it through a separately approved,
fenced handover profile under the RTC control-authority fencing contract with a
durable predecessor/successor record; or mark it indeterminate. A new epoch MUST
NOT silently adopt an unresolved operation from the retired epoch. The initial
single-host profile has no live handover, so RTC restart marks every
acknowledged-but-unresolved operation indeterminate unless a terminal
disposition was retained durably. Indeterminate disposition alone does not
prove that an endpoint effect can no longer occur and therefore does not
satisfy the RTC-OPS-002 replacement guard without its separately required
ordering, reset, restart, or other no-later-application evidence.

A deployment that promises completion across owner-process loss MUST durably
retain enough accepted-operation state to reconcile that promise. Without that
profile, recovery MUST mark every known acknowledged-but-unresolved operation
indeterminate and MUST expose any range whose identities were lost as an audit
gap. It MUST NOT infer application from a client acknowledgement or from later
unrelated state.

Delivery itself need not be exactly once. Status and event projection MAY be
retried, and a client MUST reduce repeated identified results idempotently.

Verification intent (informative): interrupt every operation at each stage,
retire the RTC authority epoch, and restart the owner and observers. Reject a
handover record in the initial profile; if a separately approved fencing
profile is later selected, exercise its transfer and verify one reconstructable
disposition, identified indeterminate result, explicit fenced transfer, or
explicit gap under the declared durability policy.

### RTC-AUDIT-004 — Strict-path isolation and durability

Audit formatting, file I/O, database work, network export, and retention MUST
remain outside the correction-critical path. The event producer MUST use finite
pre-admitted capacity and a declared full policy. Loss MUST be counted and
identified sufficiently to mark the audit range incomplete.

A deployment MAY require durable admission of a protected operator command.
In that profile, the RTC application MUST delay its acceptance acknowledgement
until the event reaches the declared durability watermark; it MUST NOT block a
frame-processing or device callback on storage I/O.

Verification intent (informative): stall and fail the recorder, exhaust event
capacity, and crash at every durability boundary; verify correction-path
isolation, explicit loss, and no durable index entry referring to unavailable
bytes.

### RTC-AUDIT-005 — Reconstruction and safe replay

The sealed append-only records for every allocated deployment candidate,
generation-specific resolved manifests for activated candidates ordered by
their explicit activation predecessor and successor identities, event log,
scientific streams, command results, metric intervals, and loss summary MUST be
sufficient to determine which deployment, artifacts, properties, parameters,
execution profile, execution-service process and client-node incarnation,
compiled graph and preparation attestation,
RTC-DM-008 correction-authority grant and active interval, complete source-
state key and effective settings,
complete input-acquisition or bounded join membership,
applicable scoped RTC-FRAME-004
generation set, complete clock-mapping record used by each retained cross-clock
result,
demanded command, fail-safe device intervention, and truthful device result
were authoritative
for each recorded acquisition within the supported profile. Unknown gaps MUST
remain explicit rather than being filled from later state.
Intentional retention under RTC-RECORD-001 MAY remove a declared sealed unit;
the retained catalog tombstone then proves the unit's identity, covered ranges,
and disposition, but the removed scientific content MUST NOT be described as
available or reconstructable.

Each run MUST identify an independently supervised run-catalog recovery owner
outside the RTC application process and its failure domain, not merely a
different event-author identity in that process. Every deployment activated in
that run MUST bind the same recovery-owner service. Changing that service
requires a new run; configuration alone MUST NOT create an interval with no
owner or two concurrent sealing owners.
After loss of the RTC application or an ordinary candidate, event, stream,
index, or closure writer, the recovery owner MUST discover every unsealed
candidate and run record. It MUST append an independently
authored terminal recovery record that links the process-loss evidence, last
durable watermarks, recovered tails, and explicit unknown ranges, or MUST leave
the object visibly unsealed with a retained recovery-failure reason. It MUST NOT
rewrite a prior manifest, event, author sequence, or normal termination reason,
and an unsealed or recovery-failed object MUST NOT be reported as a complete
run.

Loss of the recovery owner MUST leave affected objects visibly unsealed until
that service or an admitted replacement with a new event-author identity
repeats recovery. Restart of the recovery owner MUST NOT weaken the evidence or
permit it to impersonate either the RTC or its own prior incarnation.

Reading or reducing an audit record MUST have no actuator side effect. A tool
that submits a recorded command to a live or simulated target creates a new
identified operation subject to current authorization, validation, and safe
state.

Verification intent (informative): reconstruct selected runs solely from their
catalogs, compare every retained boundary with its scientific oracle, and prove
that ordinary inspection and replay cannot activate a physical DM. Crash the
RTC and catalog recovery owner before and after every candidate, activation,
segment, watermark, and final-run boundary; accept only an independently sealed
recovery record or a visibly incomplete object with exact retained gaps.

### RTC-AUDIT-006 — Execution-composite provenance

Every execution-composite candidate record MUST retain the selected Calculon
execution profile, stable composite identity, canonical graph configuration
and digest, expected external ports and operation identities from resolution,
then append the observed service invocation and authenticated process
incarnation, PipeWire core/client/node binding, prepared property, parameter,
and artifact generations, and applicable RTC-FRAME-004 generation-set scope as
each becomes available. An unavailable future binding MUST remain explicitly
absent at the candidate's current state. Every resolved deployment manifest
written before activation MUST contain all applicable bindings. For
`fgn-native`, the record and manifest MUST also retain the FGN descriptor,
plugin or bundle, daemon invocation, coordinator, worker policy, and native
build identities needed to reproduce that profile.

For `julia-runtime`, the manifest and RTC-EXEC-002 preparation attestation MUST
together retain:

- Julia executable and runtime version;
- `Project.toml` and `Manifest.toml` identities and content digests;
- sysimage identity and digest when one is used;
- every loaded package name, UUID, and version;
- every trusted source path, expected module, and content digest;
- provider module and `calculon_operation_provider()` entry-point identity;
- expected and registered versioned operation identities;
- canonical graph configuration, compiled-graph digest, lowering/backend
  explanation, and external port surface;
- complete runtime, garbage-collector, BLAS, and helper-thread inventory, every
  transient preparation helper process and terminal result, and the warmup
  result;
- execution-service process incarnation and PipeWire client/node bindings; and
- requested, prepared, and active property, parameter, artifact, and generation-
  set identities.

Every execution-composite launch, provider-registration result, preparation
state, attestation, link creation, admission, activation, first authoritative
work unit, failure, deadline result, unlink, replacement, process termination,
and restart boundary MUST be an identified event or resolve through an
immutable retained binding. A restart MUST create a new process incarnation and
candidate chain and MUST NOT overwrite or extend the prior chain. A later
matching graph digest or provider set MUST NOT be treated as continuity.
Missing runtime or provider provenance, an unattested prepared graph, or a gap
covering activation or active-generation adoption MUST make the affected
execution interval explicitly unreconstructable. An attestation records what
the candidate reported and what the RTC validated; it MUST NOT be promoted to
strict-runtime qualification without the independent RTC-PERF-007 evidence.

Verification intent (informative): reconstruct equivalent `fgn-native` and
`julia-runtime` runs from their manifests, attestations, events, and stream
records; change each executable, environment, provider, operation, graph,
thread, property, parameter, and process field independently and verify a new
identity or admission failure. Crash and restart the Julia service at every
candidate and active boundary, remove each provenance record in turn, and
accept only an exact reconstruction or an explicitly bounded unknown interval.
