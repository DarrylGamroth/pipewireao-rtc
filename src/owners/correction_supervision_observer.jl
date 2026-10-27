import PipeWireAO
import ..Schemas, ..Artifacts

public Observer, snapshot, property_info, request_rearm!, rearm_status

const OBSERVATION_PREFIX = "pipewireao.correction-supervision."
const FEEDBACK_SCHEMA = Schemas.identifier("pdm_constraint_feedback")
const OBSERVATION_STATES = (:Disabled, :Unknown, :Clear, :Pending, :Tripped)
const OBSERVATION_REASONS = (:none, :disabled, :clear, :pending, :persistent_clipping,
    :already_tripped, :missing_feedback, :malformed_feedback, :malformed_sample,
    :stale_sample, :future_sample, :wrong_owner, :invalidated, :reset,
    :discontinuity, :corrupted)
const OBSERVATION_ACTIONS = (:none, :monitor_only, :hold, :restore_reference)

# All concurrently accessed payload fields are atomic, including the seqlock
# version. Sequential consistency prevents payload loads moving outside the
# version checks and makes the record data-race free even during a failed read.
# Only the frame writer updates this record. Readers make at most three attempts.
mutable struct PublishedObservation
    @atomic version::UInt64
    @atomic state::UInt8
    @atomic reason::UInt8
    @atomic fraction::Float64
    @atomic sequence::UInt64
    @atomic observed_ns::UInt64
    @atomic trip_sequence::UInt64
    @atomic trip_ns::UInt64
    @atomic action::UInt8
    @atomic rearm_sequence::UInt64
    @atomic rearm_ns::UInt64
    PublishedObservation() = new(0, 2, 1, NaN, 0, 0, 0, 0, 1, 0, 0)
end

struct FeedbackObservation{Name,Shape}
    supervisor::Supervisor
    tolerance::Float64
    published::PublishedObservation
end

mutable struct RearmMailbox
    @atomic request_token::UInt64
    @atomic issued::UInt64
    @atomic version::UInt64
    @atomic acknowledged_token::UInt64
    @atomic accepted::Bool
    RearmMailbox() = new(0, 0, 0, 0, false)
end

"""Frame-thread supervision of prevalidated public feedback outputs.

`formats` is the public output-formats NamedTuple. `policies` has exact output
names and values `(configuration, tolerance, schema, shape, layout)`. Extents,
layout, Float32 element type and PDM constraint-feedback schema must match the
public format before construction. There are at most 64 declared outputs.

Only one serialized frame/reset/invalidation caller may mutate this object.
Control threads use `snapshot` or the callable property getter, never its
Supervisors. The frame callback borrows arrays/metadata only for its duration.
Its primary metadata boundary uses the scientific owner's concrete `AdmittedSampleMetadata`
presence record; an absent record never exposes its placeholder value. Direct
`SampleMetadata`/`nothing` inputs remain supported for array-only callers.
Header sequence is used verbatim; persistence and freshness use the owner clock,
never model PTS. A trip identity/action remains published until explicit rearm
or owner replacement, including across reset, invalidation, clear samples and
missed property polls. The injected clock must support concurrent reads from
the frame writer and property getter.
After trusted feedback, Reset makes observations unavailable until a new owner
is constructed. Header alone cannot fence an acquisition-generation restart
against queued old buffers. Startup preparation before trusted feedback does
not set this fence. Invalidation alone can resume with new trusted feedback.
`request_rearm!` stages intent only; it never mutates a Supervisor. At the next
successful frame, the frame writer accepts it only against new, fresh clear
feedback for every latched output, or publishes a one-shot refusal. No closure,
reference restoration or native effect follows from supervision rearm.
"""
struct Observer{B,C}
    bindings::B
    owner_instance::Int64
    clock::C
    rearm::RearmMailbox
    reset_unverified::Threads.Atomic{Bool}
end

function observation_clock(clock)
    now = clock()
    unsigned(now) || throw(ArgumentError("supervision clock must return nonnegative UInt64 nanoseconds"))
    return UInt64(now)
end

validated_configuration(configuration::Configuration) = configuration
validated_configuration(_) = throw(ArgumentError("supervision requires Configuration"))
validated_tolerance(_) = throw(ArgumentError("feedback tolerance must be finite and nonnegative"))
validated_tolerance(::Bool) = throw(ArgumentError("feedback tolerance must be finite and nonnegative"))
function validated_tolerance(tolerance::Real)
    isfinite(tolerance) && tolerance >= 0 ||
        throw(ArgumentError("feedback tolerance must be finite and nonnegative"))
    converted = Float64(tolerance)
    isfinite(converted) || throw(ArgumentError("feedback tolerance must fit Float64"))
    return converted
end
feedback_count(::FeedbackObservation{Name,Shape}) where {Name,Shape} = only(Shape)

function Observer(formats::NamedTuple, policies::NamedTuple; owner_instance, clock=time_ns)
    owner(owner_instance) || throw(ArgumentError("owner incarnation must be positive and fit Int64"))
    1 <= length(policies) <= 64 || throw(ArgumentError("supervision requires 1:64 feedback outputs"))
    observation_clock(clock)
    bindings = map(keys(policies)) do name
        hasproperty(formats, name) || throw(ArgumentError("unknown supervision feedback output $name"))
        format, policy = getproperty(formats, name), getproperty(policies, name)
        configuration = validated_configuration(policy.configuration)
        tolerance = validated_tolerance(policy.tolerance)
        policy.schema == format.schema == FEEDBACK_SCHEMA ||
            throw(ArgumentError("supervision requires the exact PDM constraint-feedback schema"))
        format.element_type === Float32 || throw(ArgumentError("feedback must have Float32 elements"))
        shape = Artifacts.checked_shape(format.shape, sizeof(Float32))
        policy.shape == format.shape && length(shape) == 1 ||
            throw(ArgumentError("feedback must match the declared nonempty rank-one shape"))
        isequal(policy.layout, format.layout) || throw(ArgumentError("feedback layout/order differs from the public format"))
        FeedbackObservation{name,shape}(Supervisor(configuration, owner_instance),
            tolerance, PublishedObservation())
    end
    # Reuse the repository's decoded-array bound for aggregate callback work;
    # the configured sum, not just an individual output, is bounded cold.
    remaining = Artifacts.MAX_IMAGE_BYTES ÷ sizeof(Float32)
    for binding in bindings
        feedback_count(binding) <= remaining || throw(ArgumentError("combined supervision feedback exceeds the decoded-array byte bound"))
        remaining -= feedback_count(binding)
    end
    observer = Observer(bindings, Int64(owner_instance), clock, RearmMailbox(),
        Threads.Atomic{Bool}(false))
    foreach(binding -> publish!(binding, Recommendation(:none, :none, false)), bindings)
    return observer
end

@inline code(values::Tuple, value::Symbol) = UInt8(something(findfirst(==(value), values), 1))

function publish!(binding::FeedbackObservation, result::Recommendation)
    sm, published = binding.supervisor, binding.published
    version = @atomic published.version
    @atomic published.version = version + UInt64(1)
    @atomic published.state = code(OBSERVATION_STATES, state(sm))
    @atomic published.reason = code(OBSERVATION_REASONS, result.reason)
    @atomic published.fraction = something(sm.last_fraction, NaN)
    @atomic published.sequence = sm.last_sequence
    @atomic published.observed_ns = sm.last_observed_ns
    if result.action !== :none
        @atomic published.trip_sequence = sm.last_sequence
        @atomic published.trip_ns = sm.last_observed_ns
        @atomic published.action = code(OBSERVATION_ACTIONS, result.action)
    end
    @atomic published.version = version + UInt64(2)
    return nothing
end

function snapshot(binding::FeedbackObservation)
    published = binding.published
    for _ in 1:3
        before = @atomic published.version
        isodd(before) && continue
        s = @atomic published.state
        r = @atomic published.reason
        fraction = @atomic published.fraction
        sequence = @atomic published.sequence
        observed_ns = @atomic published.observed_ns
        trip_sequence = @atomic published.trip_sequence
        trip_ns = @atomic published.trip_ns
        action = @atomic published.action
        rearm_sequence = @atomic published.rearm_sequence
        rearm_ns = @atomic published.rearm_ns
        after = @atomic published.version
        before == after && return (;state=OBSERVATION_STATES[s],
            reason=OBSERVATION_REASONS[r], fraction, sequence, observed_ns,
            trip_sequence, trip_ns, action=OBSERVATION_ACTIONS[action], rearm_sequence, rearm_ns)
    end
    return nothing
end

"""Read bounded, coherent snapshots without touching frame-owned mutable state.

A busy writer yields `nothing` for that output after three attempts. This is
unavailable evidence, not permission to act; retry only on a later ordinary poll.
"""
snapshot(observer::Observer) = map(snapshot, observer.bindings)

@inline function feedback_fraction(values::AbstractVector{Float32}, ::Val{Shape}, tolerance) where {Shape}
    size(values) == Shape || return nothing
    clipped = 0
    finite = true
    # Independent exact integer/Boolean reductions permit LLVM vectorization
    # without relaxed floating-point semantics or early-exit loop branches.
    for value in values
        finite &= isfinite(value)
        clipped += abs(Float64(value)) > tolerance
    end
    finite || return nothing
    return clipped / length(values)
end
@inline feedback_fraction(values, shape, tolerance) = nothing

# Header metadata is transport-neutral SampleMetadata (or nothing). The
# core stays independent of the optional scientific package; exact field access
# specializes on that concrete isbits type at the extension boundary.
@inline metadata_reason(::Nothing) = :missing_feedback
@inline function metadata_reason(metadata)
    hasproperty(metadata, :sequence) && hasproperty(metadata, :offset) &&
        hasproperty(metadata, :corrupted) && hasproperty(metadata, :discontinuity) || return :malformed_sample
    unsigned(metadata.sequence) && metadata.offset == 0 || return :malformed_sample
    metadata.corrupted === false || return :corrupted
    metadata.discontinuity === false || return :discontinuity
    return :none
end

@inline function observe_header!(binding::FeedbackObservation{Name,Shape}, observer::Observer,
        outputs::NamedTuple, header, now::UInt64) where {Name,Shape}
    cause = metadata_reason(header)
    if cause !== :none
        publish!(binding, reject!(binding.supervisor, cause))
        return nothing
    end
    fraction = feedback_fraction(getproperty(outputs, Name), Val(Shape), binding.tolerance)
    result = observe!(binding.supervisor, observer.owner_instance, header.sequence, now,
        fraction; now_ns=now)
    publish!(binding, result)
    return nothing
end

function observe_frame!(binding::FeedbackObservation{Name}, observer::Observer,
        outputs::NamedTuple, metadata::NamedTuple, now::UInt64) where {Name}
    if !hasproperty(outputs, Name) || !hasproperty(metadata, Name)
        publish!(binding, reject!(binding.supervisor, :missing_feedback))
        return nothing
    end
    record = getproperty(metadata, Name)
    # Branch before extracting the concrete header. Returning a large header /
    # nothing union here can box unrelated metadata when output records differ.
    if hasproperty(record, :present) && hasproperty(record, :value)
        if record.present === true
            observe_header!(binding, observer, outputs, record.value, now)
        else
            publish!(binding, reject!(binding.supervisor, :missing_feedback))
        end
    else
        observe_header!(binding, observer, outputs, record, now)
    end
    return nothing
end

function (observer::Observer)(::Val{:frame}, outputs::NamedTuple, metadata::NamedTuple)
    request = @atomic observer.rearm.request_token
    now = observer.clock()
    if !unsigned(now)
        foreach(binding -> publish!(binding, reject!(binding.supervisor, :malformed_sample)), observer.bindings)
        return nothing
    end
    if observer.reset_unverified[]
        invalidate_observations!(observer, :reset)
    else
        foreach(binding -> observe_frame!(binding, observer, outputs, metadata, UInt64(now)), observer.bindings)
    end
    adopt_rearm!(observer, request, UInt64(now))
    return nothing
end

(observer::Observer)(::Val{:invalidated}) = invalidate_observations!(observer, :invalidated)
function (observer::Observer)(::Val{:reset})
    # Header sequence can restart in a new acquisition generation. A generic
    # stopped-owner reset does not prove queued old buffers were drained. Keep
    # evidence unavailable until owner replacement rather than guessing an epoch.
    any(binding -> binding.supervisor.has_sample, observer.bindings) &&
        (observer.reset_unverified[] = true)
    return invalidate_observations!(observer, :reset)
end
function invalidate_observations!(observer::Observer, cause::Symbol)
    foreach(binding -> publish!(binding, reject!(binding.supervisor, cause)), observer.bindings)
    return nothing
end

"""Stage explicit rearm intent for this exact owner, returning its token.

Zero means refused (wrong owner, busy mailbox or exhausted token space). A token
is not rearm success. The frame writer consumes it once on a later successful
frame and publishes `rearm_status`. No polling or automatic retry occurs here.
All currently latched outputs must supply new fresh clear evidence; otherwise
none rearms. Unlatched outputs do not need rearm. Only the frame writer calls
Supervisor `rearm!`; actual owner/sequence/freshness checks are unchanged.
Reset-unverified observers refuse rearm until owner replacement.
"""
function request_rearm!(observer::Observer, owner_instance)
    observer.reset_unverified[] && return UInt64(0)
    owner(owner_instance) && owner_instance == observer.owner_instance || return UInt64(0)
    mailbox = observer.rearm
    claim = @atomicreplace mailbox.request_token UInt64(0) => typemax(UInt64)
    claim.success || return UInt64(0)
    issued = @atomic mailbox.issued
    if issued >= typemax(UInt64) - 1
        @atomic mailbox.request_token = UInt64(0)
        return UInt64(0)
    end
    token = issued + UInt64(1)
    @atomic mailbox.issued = token
    @atomic mailbox.request_token = token
    return token
end

function can_rearm(binding::FeedbackObservation, now::UInt64)
    sm = binding.supervisor
    return !sm.tripped || (sm.has_sample && sm.last_observed_ns == now &&
        sm.last_fraction !== nothing && sm.last_fraction <= sm.configuration.clear_fraction &&
        now >= sm.last_sample_ns && now - sm.last_sample_ns <= sm.configuration.max_gap_ns)
end

function adopt_rearm!(observer::Observer, token::UInt64, now::UInt64)
    token == 0 || token == typemax(UInt64) || begin
        # Clock and successful-frame observation are shared by every binding.
        # Rejected/replayed observations clear last_fraction, preventing reuse.
        accepted = !observer.reset_unverified[] &&
            any(binding -> binding.supervisor.tripped, observer.bindings) &&
            all(binding -> can_rearm(binding, now), observer.bindings)
        if accepted
            foreach(observer.bindings) do binding
                sm = binding.supervisor
                if sm.tripped
                    rearm!(sm, observer.owner_instance, sm.last_sequence; now_ns=now)
                    # Explicit rearm is the only operation that clears intent.
                    published = binding.published
                    publication_version = @atomic published.version
                    @atomic published.version = publication_version + UInt64(1)
                    @atomic published.action = UInt8(1)
                    @atomic published.trip_sequence = UInt64(0)
                    @atomic published.trip_ns = UInt64(0)
                    @atomic published.rearm_sequence = sm.last_sequence
                    @atomic published.rearm_ns = now
                    @atomic published.state = code(OBSERVATION_STATES, state(sm))
                    @atomic published.reason = code(OBSERVATION_REASONS, :clear)
                    @atomic published.version = publication_version + UInt64(2)
                end
            end
        end
        mailbox = observer.rearm
        mailbox_version = @atomic mailbox.version
        @atomic mailbox.version = mailbox_version + UInt64(1)
        @atomic mailbox.accepted = accepted
        @atomic mailbox.acknowledged_token = token
        @atomic mailbox.version = mailbox_version + UInt64(2)
        @atomic mailbox.request_token = UInt64(0)
    end
    return nothing
end

"Read bounded coherent frame-writer rearm acknowledgement, or nothing if busy."
function rearm_status(observer::Observer)
    mailbox = observer.rearm
    for _ in 1:3
        before = @atomic mailbox.version
        isodd(before) && continue
        token = @atomic mailbox.acknowledged_token
        accepted = @atomic mailbox.accepted
        after = @atomic mailbox.version
        if before == after
            request = @atomic mailbox.request_token
            return (; requested_token=request == typemax(UInt64) ? UInt64(0) : request,
                acknowledged_token=token, result=token == 0 ? :none : accepted ? :rearmed : :refused)
        end
    end
    return nothing
end

# These control-thread operations may allocate native Pods. None runs on the
# frame path. Source sequences use strings to preserve the full UInt64 domain
# in SPA values; monotonic times are similarly lossless, never invented counters.
function property_info(observer::Observer)
    flags = PipeWireAO.SPA.PROPERTY_READONLY
    infos = PipeWireAO.SPA.PropInfo[
        PipeWireAO.SPA.PropInfo(OBSERVATION_PREFIX * "version", PipeWireAO.Pod(Int32(1)); flags, params=true),
        PipeWireAO.SPA.PropInfo(OBSERVATION_PREFIX * "owner-instance", PipeWireAO.Pod(observer.owner_instance); flags, params=true)]
    for (name, value) in (("rearm-request-token", "0"), ("rearm-acknowledged-token", "0"), ("rearm-result", "none"))
        push!(infos, PipeWireAO.SPA.PropInfo(OBSERVATION_PREFIX * name, PipeWireAO.Pod(value); flags, params=true))
    end
    for binding in observer.bindings
        prefix = OBSERVATION_PREFIX * string(output_name(binding)) * "."
        for (field, value) in (("state", "Unknown"), ("reason", "none"),
                ("fraction", NaN), ("sequence", "0"), ("observed-ns", "0"),
                ("trip-sequence", "0"), ("trip-ns", "0"), ("rearm-sequence", "0"), ("rearm-ns", "0"), ("action", "none"), ("fresh", false),
                ("max-gap-ns", string(binding.supervisor.configuration.max_gap_ns)))
            push!(infos, PipeWireAO.SPA.PropInfo(prefix * field, PipeWireAO.Pod(value); flags, params=true))
        end
    end
    return infos
end

output_name(::FeedbackObservation{Name}) where {Name} = Name
output_names(observer::Observer) = map(output_name, observer.bindings)

function (observer::Observer)(graphprops::PipeWireAO.SPA.Props, available::Bool)
    now = observer.clock()
    extras = Pair{String,PipeWireAO.Pod}[
        OBSERVATION_PREFIX * "version" => PipeWireAO.Pod(Int32(1)),
        OBSERVATION_PREFIX * "owner-instance" => PipeWireAO.Pod(observer.owner_instance)]
    ack = rearm_status(observer)
    for (field, entry) in (("rearm-request-token", ack === nothing ? "0" : string(ack.requested_token)),
            ("rearm-acknowledged-token", ack === nothing ? "0" : string(ack.acknowledged_token)),
            ("rearm-result", ack === nothing ? "unavailable" : string(ack.result)))
        push!(extras, OBSERVATION_PREFIX * field => PipeWireAO.Pod(entry))
    end
    for binding in observer.bindings
        value = snapshot(binding)
        fresh = value !== nothing && available && unsigned(now) &&
            value.state in (:Clear, :Pending, :Tripped) && isfinite(value.fraction) &&
            now >= value.observed_ns && now - value.observed_ns <= binding.supervisor.configuration.max_gap_ns
        current = value === nothing ? :Unknown :
            value.state in (:Disabled, :Tripped) || fresh ? value.state : :Unknown
        prefix = OBSERVATION_PREFIX * string(output_name(binding)) * "."
        for (field, entry) in (("state", string(current)),
                ("reason", value === nothing ? "unavailable" : string(value.reason)),
                ("fraction", value === nothing ? NaN : value.fraction),
                ("sequence", value === nothing ? "0" : string(value.sequence)),
                ("observed-ns", value === nothing ? "0" : string(value.observed_ns)),
                ("trip-sequence", value === nothing ? "0" : string(value.trip_sequence)),
                ("trip-ns", value === nothing ? "0" : string(value.trip_ns)),
                ("rearm-sequence", value === nothing ? "0" : string(value.rearm_sequence)),
                ("rearm-ns", value === nothing ? "0" : string(value.rearm_ns)),
                ("action", value === nothing ? "none" : string(value.action)), ("fresh", fresh),
                ("max-gap-ns", string(binding.supervisor.configuration.max_gap_ns)))
            push!(extras, prefix * field => PipeWireAO.Pod(entry))
        end
    end
    return PipeWireAO.SPA.Props(extras)
end
