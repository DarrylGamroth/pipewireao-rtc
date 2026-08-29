# PipeWireAO RTC audit and reconstruction contract

Status: proposed normative companion contract

Review date: 2026-08-29

## Authority and applicability

This document defines auditable progression, causal event identity, terminal
disposition, durability isolation, run reconstruction, and safe replay for the
[PipeWireAO RTC system architecture](architecture.md). The
[operational architecture](operations.md) owns recorder topology
and storage layout. The
[time, causality, and performance contract](time-and-performance.md)
owns clock domains, causal ordering, replay pacing, and timing evidence. The
[scientific data and command contract](scientific-data-and-command-contracts.md)
owns DM command stages and outcomes.

PipeWire object and parameter acknowledgements are observations at generic API
boundaries. They do not replace the RTC target's domain-specific admission,
activation, device-result, or durability evidence.

Uppercase requirement terms use the meanings defined by BCP 14 (RFC 2119 and
RFC 8174). Lowercase forms are ordinary prose.

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
| Recorder durability | received, appended, durable, indexed, sealed or lost |

Verification intent (informative): delay and fail every stage independently;
verify that clients and the run record never advance to a later stage from an
earlier acknowledgement.

### RTC-AUDIT-002 — Causal audit identity

Every audit event MUST identify its operation family, stable target,
correlation or operation identity, target-authored sequence, deployment and
configuration generations relevant to the event, semantic event time, and
immediate predecessor or cause when one exists. Acquisition-derived events
MUST carry or resolve to their acquisition identity.

Recorder arrival order and wall-clock proximity MUST NOT create a causal edge.
Repeated observation of the same identified event MUST be idempotent for
reducers, indexes, and replay tools.

Verification intent (informative): reorder, duplicate, and delay event
publication; reconstruct the same progression and identify explicit gaps.

### RTC-AUDIT-003 — Terminal disposition

While it retains authority for an accepted protected operation, the owner MUST
produce one terminal disposition: applied, active, rejected, expired, aborted,
held, failed, indeterminate, or another operation-specific terminal result
defined by its schema. Cancellation, orderly shutdown, fault handling, or
controller disconnect MUST transfer or terminate every retained operation
rather than silently forget it.

A deployment that promises completion across owner-process loss MUST durably
retain enough accepted-operation state to reconcile that promise. Without that
profile, recovery MUST mark every known acknowledged-but-unresolved operation
indeterminate and MUST expose any range whose identities were lost as an audit
gap. It MUST NOT infer application from a client acknowledgement or from later
unrelated state.

Delivery itself need not be exactly once. Status and event projection MAY be
retried, and a client MUST reduce repeated identified results idempotently.

Verification intent (informative): interrupt every operation at each stage,
restart the owner and observers, and verify one reconstructable disposition,
an identified indeterminate result, or an explicit gap under the declared
durability policy.

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

The resolved manifest, event log, scientific streams, command results, metric
intervals, and loss summary MUST be sufficient to determine which deployment,
artifacts, properties, parameters, correction authority, and demanded command
were authoritative for each recorded acquisition within the supported profile.
Unknown gaps MUST remain explicit rather than being filled from later state.

Reading or reducing an audit record MUST have no actuator side effect. A tool
that submits a recorded command to a live or simulated target creates a new
identified operation subject to current authorization, validation, and safe
state.

Verification intent (informative): reconstruct selected runs solely from their
catalogs, compare every retained boundary with its scientific oracle, and prove
that ordinary inspection and replay cannot activate a physical DM.
