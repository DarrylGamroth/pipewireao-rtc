# Included in CorrectionRecovery. Observation interfaces describe owner evidence;
# they neither admit effects nor select Hsm phases.

"""Owner evidence identified by `owner_instance`, `operation_token` and
`observation_serial`. Implement those accessors for another representation;
the supplied records use fields with the same meanings. Serial values belong
to one strictly increasing owner sequence across observation kinds.
"""
abstract type AbstractObservation end

"""Atomic correction-loop evidence. Implement `requested_generation`,
`active_generation` and `closed` in addition to the AbstractObservation identity
interface. The controller-scope trait and comparisons use these accessors, so
adapters can supply another layout without copying it into LoopObservation.
Single-controller values are UInt64 generations and Bool closure; coupled values
are equally sized ordered tuples of those types. Invalid shapes have no scope.
"""
abstract type AbstractLoopObservation <: AbstractObservation end

"""Scalar or coupled controller cardinality used to interpret loop evidence.

Owner/token identity and the ordered controller names are bound separately by
the coordinator and native adapter. Coupled comparisons preserve that order.
"""
abstract type AbstractControllerScope end
"One correction controller with a scalar generation and Boolean closure."
struct SingleController <: AbstractControllerScope end
"An ordered scope of N independent correction controllers."
struct CoupledControllers{N} <: AbstractControllerScope end

"""Exact atomic Boolean/generation readback, with an owner-produced serial.

All observations in an operation share one strictly increasing serial sequence
assigned by the serialized owner when obtaining evidence. A serial is not a
caller readiness assertion or evidence of physical settling. Token zero is used
only for initial qualification. Adapters must not relabel cached observations.
"""
struct LoopObservation{G,V} <: AbstractLoopObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    requested_generation::G
    active_generation::G
    closed::V
end

"""Graph recovery status; `:applied` establishes scope adoption, not reference arrival."""
struct RecoveryObservation <: AbstractObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    requested_generation::UInt64
    active_generation::UInt64
    status::Symbol
    closure_inhibited::Bool
end

"""Fresh command-reference, coherence and RTC readiness evidence for this scope.

The scientific owner supplies these facts after scope adoption. `reference_reached`
means the declared command reference was reached; it does not claim physical
settling. `coherent` covers controller, participants and delayed feedback.
"""
struct ReferenceObservation <: AbstractObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    generation::UInt64
    reference_reached::Bool
    coherent::Bool
    ready::Bool
end

"""Fresh release adoption and revalidated closure prerequisites, obtained together.

The owner must establish these facts after the release callback boundary; it
cannot copy the pre-release reference/readiness observation into this record.
"""
struct ReleaseObservation{V} <: AbstractObservation
    owner_instance::Int64
    token::UInt64
    serial::UInt64
    generation::UInt64
    released::Bool
    closed::V
    reference_reached::Bool
    coherent::Bool
    ready::Bool
end

"""
    owner_instance(observation)

Return the exact owner incarnation that produced the observation.
"""
owner_instance(observation::AbstractObservation) = observation.owner_instance
"""
    operation_token(observation)

Return the operation token, with zero reserved for initial qualification.
"""
operation_token(observation::AbstractObservation) = observation.token
"""
    observation_serial(observation)

Return the acquisition serial assigned by the owner.
"""
observation_serial(observation::AbstractObservation) = observation.serial
"""
    requested_generation(observation)

Return the requested controller generation or ordered generation tuple.
"""
requested_generation(observation::Union{AbstractLoopObservation,RecoveryObservation}) =
    observation.requested_generation
"""
    active_generation(observation)

Return the applied controller generation or ordered generation tuple.
"""
active_generation(observation::Union{AbstractLoopObservation,RecoveryObservation}) =
    observation.active_generation
"""
    closed(observation)

Return the applied Boolean closure or ordered controller selection.
"""
closed(observation::Union{AbstractLoopObservation,ReleaseObservation}) = observation.closed

"""
    controller_scope(observation)

Return SingleController or CoupledControllers{N} for valid evidence.

Both requested and active generations and every closure component must have
the declared representation. Return `nothing` for malformed evidence. This is
representation validation, not a claim of freshness, adoption or coherence.
"""
controller_scope(observation::AbstractLoopObservation) = _controller_scope(
    requested_generation(observation),
    active_generation(observation),
    closed(observation),
)
controller_scope(observation::ReleaseObservation) = _closure_scope(closed(observation))
_controller_scope(::UInt64, ::UInt64, ::Bool) = SingleController()
_controller_scope(::NTuple{N,UInt64}, ::NTuple{N,UInt64}, ::NTuple{N,Bool}) where {N} =
    CoupledControllers{N}()
_controller_scope(_, _, _) = nothing
_closure_scope(::Bool) = SingleController()
_closure_scope(::NTuple{N,Bool}) where {N} = CoupledControllers{N}()
_closure_scope(_) = nothing

"""
    same_scope(a, b)

Return whether evidence has the same scalar/coupled representation and controller count.
"""
same_scope(a, b) = same_scope(controller_scope(a), controller_scope(b))
same_scope(::AbstractControllerScope, ::AbstractControllerScope) = false
same_scope(::S, ::S) where {S<:AbstractControllerScope} = true
same_scope(::Nothing, ::Union{Nothing,AbstractControllerScope}) = false
same_scope(::AbstractControllerScope, ::Nothing) = false

"""
    all_open(observation)

Return whether every controller in the selection is open.
"""
all_open(observation::Union{AbstractLoopObservation,ReleaseObservation}) =
    all_open(controller_scope(observation), observation)
all_open(::SingleController, observation) = !closed(observation)
all_open(::CoupledControllers, observation) = all(!, closed(observation))
all_open(::Nothing, observation) = false
"""
    all_closed(observation)

Return whether every controller in the selection is closed.
"""
all_closed(observation::Union{AbstractLoopObservation,ReleaseObservation}) =
    all_closed(controller_scope(observation), observation)
all_closed(::SingleController, observation) = closed(observation)
all_closed(::CoupledControllers, observation) = all(identity, closed(observation))
all_closed(::Nothing, observation) = false

"""
    generations_match(observation)

Return whether all requested controller generations have been adopted.
"""
generations_match(observation::AbstractLoopObservation) =
    controller_scope(observation) !== nothing &&
    requested_generation(observation) == active_generation(observation)

"""
    requested_before(observation, generation)

Return whether the requested generation precedes the bound generation.

For coupled controllers this is strict componentwise partial ordering: every
component must be at most its bound and at least one must be smaller.
Incomparable tuples are not stale. Callers establish scope compatibility first.
"""
requested_before(observation::AbstractLoopObservation, generation) =
    requested_before(controller_scope(observation), observation, generation)
requested_before(::SingleController, observation, generation::UInt64) =
    requested_generation(observation) < generation
function requested_before(
    ::CoupledControllers{N}, observation, generation::NTuple{N,UInt64}
) where {N}
    requested = requested_generation(observation)
    return requested != generation && all(map(<=, requested, generation))
end

"""
    active_before(observation, generation)

Return whether applied evidence precedes the bound, using componentwise ordering.
"""
active_before(observation::AbstractLoopObservation, generation) =
    active_before(controller_scope(observation), observation, generation)
active_before(::SingleController, observation, generation::UInt64) =
    active_generation(observation) < generation
function active_before(
    ::CoupledControllers{N}, observation, generation::NTuple{N,UInt64}
) where {N}
    active = active_generation(observation)
    return active != generation && all(map(<=, active, generation))
end

"""
    active_at_most(observation, generation)

Return whether each applied controller generation is at most its bound.
"""
active_at_most(observation::AbstractLoopObservation, generation) =
    active_at_most(controller_scope(observation), observation, generation)
active_at_most(::SingleController, observation, generation::UInt64) =
    active_generation(observation) <= generation
active_at_most(
    ::CoupledControllers{N}, observation, generation::NTuple{N,UInt64}
) where {N} = all(map(<=, active_generation(observation), generation))

"""
    active_at_least(observation, generation)

Return whether each applied controller generation is at least its baseline.
"""
active_at_least(observation::AbstractLoopObservation, generation) =
    active_at_least(controller_scope(observation), observation, generation)
active_at_least(::SingleController, observation, generation::UInt64) =
    active_generation(observation) >= generation
active_at_least(
    ::CoupledControllers{N}, observation, generation::NTuple{N,UInt64}
) where {N} = all(map(>=, active_generation(observation), generation))
