# Recovery observations

`CorrectionRecovery` separates evidence from phase-dependent behavior. Public
mutation functions dispatch events; Hsm handlers admit evidence, update accepted
facts and select transitions. An observation does not submit an effect or prove
physical settling. RTC-DEV-034/035 remain the authority for recovery and closure.

## Observation interface

Every AbstractObservation provides:

| Accessor | Contract |
| --- | --- |
| `owner_instance(observation)` | Exact producing owner incarnation, Int64 |
| `operation_token(observation)` | UInt64 operation token; zero only for initial qualification |
| `observation_serial(observation)` | UInt64 serial from the owner's increasing sequence across observation kinds |

AbstractLoopObservation also provides:

| Accessor | One controller | Coupled controllers |
| --- | --- | --- |
| `requested_generation(observation)` | UInt64 | Ordered NTuple{N,UInt64} |
| `active_generation(observation)` | UInt64 | Ordered NTuple{N,UInt64} |
| `closed(observation)` | Bool | Ordered NTuple{N,Bool} |

The getters must describe one stable atomic sample throughout event processing.
They must not independently read changing live properties. The default
`controller_scope` classifier returns SingleController or CoupledControllers{N}
from those values; malformed representations return `nothing`. It validates
both generation representations and closure cardinality. Owner identity and
ordered controller names are bound separately by the coordinator and adapter.

Existing LoopObservation, RecoveryObservation, ReferenceObservation and
ReleaseObservation constructors and fields remain available. Native client
snapshots implement the loop interface using typed ControllerReadback records.
Their recovery-transaction generation fields and controller-generation accessors
describe different native contracts. Compatibility property reads project the
records instead of maintaining parallel mutable columns. A version-2 singleton
remains coupled, even though it contains one controller.

## Another observation layout

An adapter implements accessors instead of copying into a specific struct:

```julia
using PipeWireAORTC, Clocks
const Recovery = PipeWireAORTC.CorrectionRecovery

struct LoopReadback{T} <: Recovery.AbstractLoopObservation
    producer::Int64
    request::UInt64
    sequence::UInt64
    sample::T
end
Recovery.owner_instance(o::LoopReadback) = o.producer
Recovery.operation_token(o::LoopReadback) = o.request
Recovery.observation_serial(o::LoopReadback) = o.sequence
Recovery.requested_generation(o::LoopReadback) = o.sample.requested
Recovery.active_generation(o::LoopReadback) = o.sample.applied
Recovery.closed(o::LoopReadback) = o.sample.closed

# Deterministic adapter example; production adapters acquire actual owner facts.
clock = CachedNanoClock(100)
coordinator = Recovery.Coordinator(Int64(801); clock)
sample = (; requested=UInt64(3), applied=UInt64(3), closed=true)
observation = LoopReadback(Int64(801), UInt64(0), UInt64(1), sample)
Recovery.qualify!(coordinator, observation)
@assert Recovery.state(coordinator) === :Closed
```

Qualification consumes fresh matching evidence. Adapters must not relabel cached
serials, substitute owner identities or turn a prior native request token into a
new operation token. The native client uses explicit zero-token qualification
and genuine persisted tokens for bound observations.

## Comparison semantics

`requested_before` and `active_before` compare an observation with its bound or
baseline. For coupled controllers, all components must be no greater and at
least one must be smaller. Thus `(3, 9)` precedes `(4, 10)`, while `(5, 9)` is
incomparable with `(4, 10)` and cannot be dismissed as stale.

`active_at_most` and `active_at_least` compare every component.
`generations_match` requires matching requested/applied generations and a valid
scope. Callers establish scope compatibility before comparing against a bound.
`all_open` and `all_closed` are both false for a mixed coupled selection.

Close staging permits some controllers to advance while others retain their
generation; protective recovery staging requires every controller to advance.
Phase handlers retain that distinction. Comparison methods do not impose a
lexicographic or total ordering on observation records.

Tests and verification are in the
[review record](reviews/20261104-observation-interfaces/REVIEW.md).
