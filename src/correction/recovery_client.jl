# Included inside CorrectionRecovery. This client runs on a serialized control
# task; it neither participates in frame processing nor creates another owner.
import ..SessionClient
import ..RunnerCodec
import ..ControlClient

public Operation, RecoveryError, protective_open!, resume!

const RecoveryRunner = RunnerCodec
const RECOVERY_PREFIX = "pipewireao-recovery:"
const RECOVERY_NODE = "pipewireao-recovery"

"""Transport dispatch seam for bounded, correlated native-control exchanges."""
abstract type AbstractRecoveryTransport end
struct SessionTransport{C<:SessionClient.Connection} <: AbstractRecoveryTransport
    connection::C
end
transport_instance(transport::SessionTransport) =
    transport.connection.selected.status.incarnation
transport_initial_token(transport::SessionTransport) =
    transport.connection.selected.status.query_token
transport_clock(::AbstractRecoveryTransport) = Clocks.SystemNanoClock()
transport_clock(transport::SessionTransport) = transport.connection.client.clock
transport_pause!(::AbstractRecoveryTransport, seconds::Float64) = sleep(seconds)
request_native!(transport::SessionTransport, command; deadline::Int64, check) =
    SessionClient.request!(transport.connection, command; deadline, check)

mutable struct RecoveryChannel{T<:AbstractRecoveryTransport}
    const transport::T
    const instance::Int64
    reply_token::Int64
    last_at_ns::Union{Nothing,Int64}
end
RecoveryChannel(transport::AbstractRecoveryTransport, instance::Int64, token::Int64) =
    RecoveryChannel(transport, instance, token, nothing)

"""Retained connection and one recovery operation; successful protection leaves Holding.

Call `resume!` explicitly to release and close. The operation never rebinds to a
replacement graph/session. A failed operation must be reconciled externally;
calling this driver again does not replay its effects.
"""
mutable struct Operation{T,C,N}
    const channel::RecoveryChannel{T}
    const coordinator::C
    const graph::String
    const controller::N
    const request_token::Int64
    const virtual_generation::UInt64
    const previous_recovery_generation::UInt64
    const baseline_sequence::UInt64
    const reference_timeout_ns::Int64
    reference_sequence::UInt64
end

"""An uncertain native operation, retaining its latched coordinator for inspection."""
struct RecoveryError{O} <: Exception
    operation::O
    message::String
end
Base.showerror(io::IO, error::RecoveryError) =
    print(io, "protective recovery failed: ", error.message)

"Exact indexed first-close readiness reported by a version-2 recovery owner."
struct ControllerReadiness
    guarded::Bool
    ready::Bool
    sequence::UInt64
    timestamp_ns::Int64
end

"One named controller's atomic native adoption and optional readiness readback."
struct ControllerReadback{R<:Union{Nothing,ControllerReadiness}}
    name::String
    closed::Bool
    requested_generation::UInt64
    active_generation::UInt64
    state::Symbol
    readiness::R
    function ControllerReadback(
        name::String,
        closed::Bool,
        requested::UInt64,
        active::UInt64,
        state::Symbol,
        readiness::R,
    ) where {R<:Union{Nothing,ControllerReadiness}}
        isempty(name) && throw(ArgumentError("recovery controller is absent"))
        state in (:Open, :Closed, :Opening, :Closing) ||
            throw(ArgumentError("invalid controller adoption state"))
        return new{R}(name, closed, requested, active, state, readiness)
    end
end
requested_generation(readback::ControllerReadback) = readback.requested_generation
active_generation(readback::ControllerReadback) = readback.active_generation
closed(readback::ControllerReadback) = readback.closed
adoption_matches(readback::ControllerReadback) =
    readback.state === (closed(readback) ? :Closed : :Open)

function validate_readbacks(::SingleController, ::ControllerReadback{Nothing})
    return nothing
end
function validate_readbacks(
    ::CoupledControllers{N}, readbacks::NTuple{N,ControllerReadback{ControllerReadiness}}
) where {N}
    1 <= N <= 16 || throw(ArgumentError("invalid recovery controller count"))
    names = map(readback -> readback.name, readbacks)
    all(name -> occursin(r"^[a-zA-Z0-9_.-]{1,128}$", name), names) ||
        throw(ArgumentError("invalid recovery controller name"))
    allunique(names) || throw(ArgumentError("duplicate recovery controllers"))
    return nothing
end
validate_readbacks(::AbstractControllerScope, _) =
    throw(ArgumentError("controller readbacks do not match their declared scope"))

"""One native owner readback, retaining its exact reply serial and request token.

The loop-observation interface exposes each controller's adoption generations.
The `requested_generation` and `active_generation` fields retain their existing
native recovery-transaction meanings; accessors select the controller readbacks.
Version 1 has one scalar readback; version 2 has an ordered coupled tuple, even
when its declared count is one. These are facts, not another recovery authority.
"""
struct RecoverySnapshot{S<:AbstractControllerScope,R} <: AbstractLoopObservation
    serial::UInt64
    owner_instance::Int64
    readbacks::R
    request_token::Int64
    release_token::UInt64
    requested_generation::UInt64
    active_generation::UInt64
    recovery_generation::UInt64
    recovery_state::Symbol
    inhibited::Bool
    reference_reached::Bool
    source_sequence::UInt64
    source_ns::Int64
    reference_timeout_ns::Int64
    function RecoverySnapshot(
        scope::S,
        serial::UInt64,
        owner::Int64,
        readbacks::R,
        request_token::Int64,
        release_token::UInt64,
        requested::UInt64,
        active::UInt64,
        recovery_generation::UInt64,
        recovery_state::Symbol,
        inhibited::Bool,
        reference_reached::Bool,
        source_sequence::UInt64,
        source_ns::Int64,
        reference_timeout_ns::Int64,
    ) where {S<:AbstractControllerScope,R}
        validate_readbacks(scope, readbacks)
        return new{S,R}(
            serial,
            owner,
            readbacks,
            request_token,
            release_token,
            requested,
            active,
            recovery_generation,
            recovery_state,
            inhibited,
            reference_reached,
            source_sequence,
            source_ns,
            reference_timeout_ns,
        )
    end
end
controller_scope(::RecoverySnapshot{S}) where {S} = S()
operation_token(snapshot::RecoverySnapshot) = UInt64(snapshot.request_token)
controller_readbacks(snapshot::RecoverySnapshot{SingleController}) = (snapshot.readbacks,)
controller_readbacks(snapshot::RecoverySnapshot{<:CoupledControllers}) = snapshot.readbacks
controller_names(snapshot::RecoverySnapshot{SingleController}) = snapshot.readbacks.name
controller_names(snapshot::RecoverySnapshot{<:CoupledControllers}) =
    map(readback -> readback.name, snapshot.readbacks)
requested_generation(snapshot::RecoverySnapshot{SingleController}) =
    requested_generation(snapshot.readbacks)
requested_generation(snapshot::RecoverySnapshot{<:CoupledControllers}) =
    map(requested_generation, snapshot.readbacks)
active_generation(snapshot::RecoverySnapshot{SingleController}) =
    active_generation(snapshot.readbacks)
active_generation(snapshot::RecoverySnapshot{<:CoupledControllers}) =
    map(active_generation, snapshot.readbacks)
closed(snapshot::RecoverySnapshot{SingleController}) = closed(snapshot.readbacks)
closed(snapshot::RecoverySnapshot{<:CoupledControllers}) = map(closed, snapshot.readbacks)
adoption_matches(snapshot::RecoverySnapshot) =
    all(adoption_matches, controller_readbacks(snapshot))
controller_states(snapshot::RecoverySnapshot{SingleController}) = snapshot.readbacks.state
controller_states(snapshot::RecoverySnapshot{<:CoupledControllers}) =
    map(readback -> readback.state, snapshot.readbacks)
controller_readiness(::RecoverySnapshot{SingleController}) = nothing
controller_readiness(snapshot::RecoverySnapshot{<:CoupledControllers}) =
    map(readback -> readback.readiness, snapshot.readbacks)

# Compatibility reads are projections, never separately stored tuple columns.
function Base.getproperty(snapshot::RecoverySnapshot, name::Symbol)
    name === :controller && return controller_names(snapshot)
    name === :closed && return closed(snapshot)
    name === :loop_requested && return requested_generation(snapshot)
    name === :loop_active && return active_generation(snapshot)
    name === :loop_state && return controller_states(snapshot)
    name === :controller_readiness && return controller_readiness(snapshot)
    return getfield(snapshot, name)
end
Base.propertynames(snapshot::RecoverySnapshot, private::Bool = false) = (
    fieldnames(typeof(snapshot))...,
    :controller,
    :closed,
    :loop_requested,
    :loop_active,
    :loop_state,
    :controller_readiness,
)
controller_scope(operation::Operation) = controller_scope(operation.coordinator)

Coordinator(
    ::SingleController,
    owner::Int64;
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    timeout_ms::Integer = 5000,
) = Coordinator(owner; clock, timeout_ms)
Coordinator(
    ::CoupledControllers{N},
    owner::Int64;
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
    timeout_ms::Integer = 5000,
) where {N} = Coordinator(owner; controllers = N, clock, timeout_ms)

function control_check!(channel::RecoveryChannel, deadline::Int64, check)
    check()
    now = Clocks.time_nanos(transport_clock(channel.transport))
    channel.last_at_ns === nothing ||
        now >= channel.last_at_ns ||
        throw(ControlClient.UnknownOutcome("protective recovery clock regressed"))
    channel.last_at_ns = now
    now < deadline ||
        throw(ControlClient.UnknownOutcome("protective recovery deadline expired"))
    return nothing
end

native_failure(::Nothing) = "native command failed or session is not Running"
native_failure(error::RecoveryRunner.RunnerError) =
    "native command failed at " * error.field * ": " * error.message

function native_reply!(channel::RecoveryChannel, command, reply::RecoveryRunner.Completion)
    reply.header.endpoint_instance == channel.instance ||
        throw(ControlClient.UnknownOutcome("session owner incarnation changed"))
    reply.header.operation == RecoveryRunner.operation_id(command) &&
    reply.header.token > channel.reply_token ||
        throw(ControlClient.UnknownOutcome("native reply is stale or uncorrelated"))
    channel.reply_token = reply.header.token
    reply.header.result == 0 &&
    reply.result !== nothing &&
    reply.lifecycle == RecoveryRunner.Running ||
        throw(ControlClient.UnknownOutcome(native_failure(reply.error)))
    return reply
end
native_reply!(::RecoveryChannel, command, reply::RecoveryRunner.Rejection) = throw(
    ControlClient.UnknownOutcome("native command was rejected: " * reply.error.message)
)

function native_request!(channel::RecoveryChannel, command; deadline::Int64, check)
    control_check!(channel, deadline, check)
    reply = request_native!(channel.transport, command; deadline, check)
    control_check!(channel, deadline, check)
    return native_reply!(channel, command, reply)
end
function running!(channel::RecoveryChannel; deadline::Int64, check)
    reply = native_request!(channel, RecoveryRunner.RunnerCommand(:status); deadline, check)
    reply.result.details.running ||
        throw(ControlClient.UnknownOutcome("session stopped running"))
    return nothing
end

function scalar_value(properties, name::String, kind::Symbol, ::Type{T}) where {T}
    scalar = properties[name]::RecoveryRunner.RunnerScalar
    scalar.kind === kind || throw(ArgumentError("wrong scalar type for " * name))
    return scalar.value::T
end
function nonnegative(value::Int64)
    value >= 0 || throw(ArgumentError("negative recovery generation or observation"))
    return UInt64(value)
end
property_long(properties, name) = nonnegative(scalar_value(properties, name, :long, Int64))

function controller_snapshot(properties, controller)
    control = "pipewireao.correction-control." * controller * ":closed."
    scalar_value(properties, control * "fault", :string, String) == "" ||
        throw(ControlClient.UnknownOutcome("correction adoption observer has a fault"))
    loop_state = Symbol(scalar_value(properties, control * "state", :string, String))
    loop_state in (:Open, :Closed, :Opening, :Closing) ||
        throw(ControlClient.UnknownOutcome("correction adoption is unverified"))
    scalar_value(properties, control * "requested", :bool, Bool)
    return ControllerReadback(
        controller,
        scalar_value(properties, controller * ":closed", :bool, Bool),
        property_long(properties, controller * ":requested-generation"),
        property_long(properties, controller * ":active-generation"),
        loop_state,
        nothing,
    )
end

function native_snapshot!(channel::RecoveryChannel, graph::String; deadline::Int64, check)
    reply = native_request!(
        channel, RecoveryRunner.RunnerCommand(:properties, graph); deadline, check
    )
    reply.result.details.graph == graph ||
        throw(ArgumentError("native graph readback changed"))
    properties = reply.result.details.properties
    p = RECOVERY_PREFIX
    version = scalar_value(properties, p * "version", :int, Int32)
    if version == 1
        controller = scalar_value(properties, p * "controller", :string, String)
        isempty(controller) && throw(ArgumentError("recovery controller is absent"))
        scope = SingleController()
        readbacks = controller_snapshot(properties, controller)
    elseif version == 2
        count = scalar_value(properties, p * "controller-count", :int, Int32)
        1 <= count <= 16 || throw(ArgumentError("invalid recovery controller count"))
        controller = ntuple(Int(count)) do index
            name = scalar_value(properties, p * "controller-$index", :string, String)
            occursin(r"^[a-zA-Z0-9_.-]{1,128}$", name) ||
                throw(ArgumentError("invalid recovery controller name"))
            name
        end
        allunique(controller) || throw(ArgumentError("duplicate recovery controllers"))
        observations = map(name -> controller_snapshot(properties, name), controller)
        scope = CoupledControllers{Int(count)}()
        readbacks = ntuple(Int(count)) do index
            key = p * "controller-$index-"
            readiness = ControllerReadiness(
                scalar_value(properties, key * "close-guarded", :bool, Bool),
                scalar_value(properties, key * "ready", :bool, Bool),
                property_long(properties, key * "observation-sequence"),
                scalar_value(
                    properties, key * "observation-monotonic-nanoseconds", :long, Int64
                ),
            )
            observation = observations[index]
            ControllerReadback(
                observation.name,
                closed(observation),
                requested_generation(observation),
                active_generation(observation),
                observation.state,
                readiness,
            )
        end
    else
        throw(ArgumentError("unsupported recovery property version"))
    end
    recovery_state = Symbol(scalar_value(properties, p * "state", :string, String))
    recovery_state in (:idle, :pending, :applied, :release_pending, :released) ||
        throw(ControlClient.UnknownOutcome("recovery state is " * string(recovery_state)))
    timeout_ms = scalar_value(properties, p * "reference-timeout-ms", :int, Int32)
    1 <= timeout_ms <= 60_000 || throw(ArgumentError("invalid owner reference timeout"))
    request_token = scalar_value(properties, p * "request-token", :long, Int64)
    request_token >= 0 || throw(ArgumentError("negative recovery request token"))
    return RecoverySnapshot(
        scope,
        UInt64(reply.header.token),
        scalar_value(
            properties, "pipewireao.correction-control.owner-instance", :long, Int64
        ),
        readbacks,
        request_token,
        property_long(properties, p * "release-token"),
        property_long(properties, p * "requested-generation"),
        property_long(properties, p * "active-generation"),
        property_long(properties, p * "recovery-generation"),
        recovery_state,
        scalar_value(properties, p * "closure-inhibited", :bool, Bool),
        scalar_value(properties, p * "reference-reached", :bool, Bool),
        property_long(properties, p * "observation-sequence"),
        scalar_value(properties, p * "observation-monotonic-nanoseconds", :long, Int64),
        Int64(timeout_ms) * Int64(1_000_000),
    )
end

function snapshot!(operation::Operation; deadline::Int64, check)
    snapshot = native_snapshot!(operation.channel, operation.graph; deadline, check)
    owner_instance(snapshot) == operation.coordinator.owner_instance &&
    controller_names(snapshot) == operation.controller &&
    same_scope(operation, snapshot) || throw(
        ControlClient.UnknownOutcome(
            "scientific graph owner or recovery controller changed"
        ),
    )
    return snapshot
end

function generation_for(reply::RecoveryRunner.Completion, node::String)
    matches = filter(
        generation -> generation.node == node, reply.result.details.generations
    )
    length(matches) == 1 ||
        throw(ArgumentError("native staging lacks one exact node generation"))
    return nonnegative(only(matches).requested::Int64)
end
function write_property!(
    operation::Operation,
    name::String,
    value::RecoveryRunner.RunnerScalar;
    deadline::Int64,
    check,
)
    return write_properties!(
        operation, Dict{String,RecoveryRunner.RunnerScalar}(name => value); deadline, check
    )
end
function write_properties!(
    operation::Operation,
    properties::Dict{String,RecoveryRunner.RunnerScalar};
    deadline::Int64,
    check,
)
    check_timeout!(operation.coordinator)
    operation.coordinator.failure === nothing ||
        throw(ControlClient.UnknownOutcome(string(operation.coordinator.failure)))
    phase_deadline = Base.checked_add(
        operation.coordinator.pending_since_ns, operation.coordinator.timeout_ns
    )
    effect_deadline = min(deadline, phase_deadline)
    running!(operation.channel; deadline = effect_deadline, check)
    # A successful readiness roundtrip can still exhaust the phase budget.
    # Recheck immediately before handing an effect to the native client.
    check_timeout!(operation.coordinator)
    operation.coordinator.failure === nothing ||
        throw(ControlClient.UnknownOutcome(string(operation.coordinator.failure)))
    reply = native_request!(
        operation.channel,
        RecoveryRunner.RunnerCommand(:properties_set, operation.graph, properties);
        deadline = effect_deadline,
        check,
    )
    reply.result.details.graph == operation.graph ||
        throw(ArgumentError("native staging graph changed"))
    return reply
end

function pause_control!(operation::Operation; deadline::Int64, check)
    check_timeout!(operation.coordinator)
    operation.coordinator.failure === nothing ||
        throw(ControlClient.UnknownOutcome(string(operation.coordinator.failure)))
    control_check!(operation.channel, deadline, check)
    remaining = Base.checked_sub(
        deadline, Clocks.time_nanos(transport_clock(operation.channel.transport))
    )
    transport_pause!(operation.channel.transport, min(Int64(10_000_000), remaining) / 1e9)
    return nothing
end

function require_open(snapshot::RecoverySnapshot)
    all_open(snapshot) && generations_match(snapshot) && adoption_matches(snapshot) ||
        throw(ControlClient.UnknownOutcome("controller is not coherently held open"))
    return nothing
end
function require_scope(operation::Operation, snapshot::RecoverySnapshot)
    snapshot.request_token == operation.request_token &&
    snapshot.recovery_generation == operation.coordinator.recovery_generation ||
        throw(ControlClient.UnknownOutcome("recovery operation identity changed"))
    return nothing
end
function fresh_reference(
    operation::Operation, snapshot::RecoverySnapshot, after_sequence::UInt64
)
    now = Clocks.time_nanos(operation.coordinator.clock)
    return snapshot.reference_reached &&
           snapshot.source_sequence > after_sequence &&
           fresh_within(
               now,
               snapshot.source_ns,
               min(operation.reference_timeout_ns, snapshot.reference_timeout_ns),
           )
end

function sample_cycle!(operation::Operation)
    now = Clocks.time_nanos(transport_clock(operation.channel.transport))
    now >= Clocks.time_nanos(operation.coordinator.clock) ||
        throw(ControlClient.UnknownOutcome("protective recovery clock regressed"))
    Clocks.update!(operation.coordinator.clock, now)
    check_timeout!(operation.coordinator)
    operation.coordinator.failure === nothing ||
        throw(ControlClient.UnknownOutcome(string(operation.coordinator.failure)))
    return nothing
end

client_failure_reason(::InterruptException) = :operation_cancelled
client_failure_reason(error) = :native_operation_failed
function recovery_error(operation::Operation, error)
    failed!(operation.coordinator, client_failure_reason(error))
    return RecoveryError(operation, sprint(showerror, error))
end

"""
    protective_open!(connection, graph; kwargs...)

Atomically inhibit closure and open/reset the scoped recovery, then leave Holding.

The recovery request is the first native mutation; ordinary open is never sent.
Every query uses the signed Int64 nanosecond deadline and cancellation check. Native
request tokens identify requests; scientific generation and owner observation
sequence independently identify reference evidence. No reply cache is relabeled.
The default timeout is the graph's configured reference timeout. Command arrival
and coherence are established by the scientific owner; physical settling is not.
"""
protective_open!(connection::SessionClient.Connection, graph::AbstractString; kwargs...) =
    protective_open!(SessionTransport(connection), graph; kwargs...)
function protective_open!(
    transport::AbstractRecoveryTransport,
    graph::AbstractString;
    deadline::Int64,
    timeout_ms::Union{Nothing,Integer} = nothing,
    reason::Symbol = :operator,
    check = ControlClient.NO_CHECK,
    expected_owner::Union{Nothing,Int64} = nothing,
    admission_deadline::Int64 = deadline,
)
    channel = RecoveryChannel(
        transport, transport_instance(transport), transport_initial_token(transport)
    )
    admission_deadline = min(deadline, admission_deadline)
    running!(channel; deadline = admission_deadline, check)
    initial = native_snapshot!(channel, String(graph); deadline = admission_deadline, check)
    expected_owner === nothing ||
        expected_owner == initial.owner_instance ||
        throw(
            ControlClient.UnknownOutcome(
                "protective recovery owner replaced before admission"
            ),
        )
    initial.recovery_state in (:idle, :released) &&
    !initial.inhibited &&
    initial.requested_generation == initial.active_generation ||
        throw(ArgumentError("another recovery transaction is pending"))
    timeout =
        timeout_ms === nothing ? Int(initial.reference_timeout_ns ÷ Int64(1_000_000)) :
        timeout_ms
    coordinator = Coordinator(
        controller_scope(initial),
        owner_instance(initial);
        clock = Clocks.CachedNanoClock(Clocks.time_nanos(transport_clock(transport))),
        timeout_ms = timeout,
    )
    initial.request_token < typemax(Int64) ||
        throw(ArgumentError("recovery request tokens exhausted"))
    operation = Operation(
        channel,
        coordinator,
        String(graph),
        controller_names(initial),
        initial.request_token + 1,
        initial.requested_generation,
        initial.recovery_generation,
        initial.source_sequence,
        min(coordinator.timeout_ns, initial.reference_timeout_ns),
        initial.source_sequence,
    )
    try
        qualify!(
            coordinator,
            LoopObservation(
                initial.owner_instance,
                UInt64(0),
                initial.serial,
                requested_generation(initial),
                active_generation(initial),
                closed(initial),
            ),
        )
        effect = request_protection!(
            coordinator, initial.owner_instance, UInt64(operation.request_token); reason
        )
        return restore_reference!(operation, effect; deadline, check, admission_deadline)
    catch error
        throw(recovery_error(operation, error))
    end
end

function restore_reference!(
    operation::Operation,
    effect::StageRecovery;
    deadline::Int64,
    check,
    admission_deadline::Int64 = deadline,
)
    coordinator = operation.coordinator
    reply = write_property!(
        operation,
        RECOVERY_PREFIX * "request-token",
        RecoveryRunner.RunnerScalar(:long, operation.request_token);
        deadline = admission_deadline,
        check,
    )
    virtual_generation = generation_for(reply, RECOVERY_NODE)
    virtual_generation > operation.virtual_generation ||
        throw(ArgumentError("recovery transaction did not advance"))
    bound = false
    pending_recovery = nothing
    snapshot = snapshot!(operation; deadline, check)
    while state(coordinator) !== :Holding
        sample_cycle!(operation)
        if pending_recovery !== nothing
            observe_recovery!(coordinator, pending_recovery)
            pending_recovery = nothing
        end
        snapshot.request_token == operation.request_token ||
            throw(ControlClient.UnknownOutcome("recovery request token changed"))
        snapshot.requested_generation == virtual_generation &&
        snapshot.active_generation <= virtual_generation ||
            throw(ControlClient.UnknownOutcome("recovery transaction generation changed"))
        if !bound && snapshot.recovery_generation > operation.previous_recovery_generation
            recovery_staged!(
                coordinator,
                effect,
                snapshot.recovery_generation;
                loop_generation = requested_generation(snapshot),
            )
            bound = true
            # The same atomic recovery transaction owns forced-open adoption.
            # Pending evidence may still show the old closed active generation.
            observe_loop!(coordinator, snapshot)
        elseif bound && state(coordinator) === :Opening
            observe_loop!(coordinator, snapshot)
        elseif bound && state(coordinator) === :RestoringReference
            observe_loop!(coordinator, snapshot)
            # Scope application needs a separate authority-processed reply token.
            if snapshot.active_generation == virtual_generation &&
                snapshot.recovery_state === :applied
                applied = snapshot!(operation; deadline, check)
                require_open(applied)
                require_scope(operation, applied)
                applied.requested_generation ==
                applied.active_generation ==
                virtual_generation &&
                applied.recovery_state === :applied &&
                applied.inhibited ||
                    throw(ControlClient.UnknownOutcome("recovery application changed"))
                generation = coordinator.recovery_generation
                pending_recovery = RecoveryObservation(
                    applied.owner_instance,
                    coordinator.token,
                    applied.serial,
                    generation,
                    generation,
                    :applied,
                    true,
                )
            end
        elseif bound && state(coordinator) === :Verifying
            require_open(snapshot)
            require_scope(operation, snapshot)
            snapshot.recovery_state === :applied && snapshot.inhibited || throw(
                ControlClient.UnknownOutcome(
                    "reference verification lost recovery inhibition"
                ),
            )
            observe_reference!(
                coordinator,
                ReferenceObservation(
                    snapshot.owner_instance,
                    coordinator.token,
                    snapshot.serial,
                    snapshot.recovery_generation,
                    fresh_reference(operation, snapshot, operation.baseline_sequence),
                    true,
                    true,
                ),
            )
            state(coordinator) === :Holding &&
                (operation.reference_sequence = snapshot.source_sequence)
        end
        state(coordinator) === :Holding && return operation
        pause_control!(operation; deadline, check)
        snapshot = snapshot!(operation; deadline, check)
    end
    return operation
end

"""
    resume!(operation; deadline, check=ControlClient.NO_CHECK, controllers=nothing)

Explicitly resume this held operation, with fresh readiness and reference evidence.

Release and close are each sent once. A refused, uncertain or expired release
never sends CloseLoop and the coordinator remains latched for reconciliation.
For a plural scope, `controllers=("name", ...)` selects the controllers to close;
the default selects all. Remaining guarded controllers may be explicitly resumed
later on the same partially closed operation, using their own fresh evidence.
That later call does not repeat recovery or release. A controller already closed
by this operation is never reopened by selecting another controller.
"""
function resume!(
    operation::Operation;
    deadline::Int64,
    check = ControlClient.NO_CHECK,
    controllers = nothing,
)
    return resume!(controller_scope(operation), operation; deadline, check, controllers)
end
resume!(::CoupledControllers, operation::Operation; deadline::Int64, check, controllers) =
    resume_controllers!(operation; deadline, check, controllers)
function resume!(
    ::SingleController, operation::Operation; deadline::Int64, check, controllers
)
    controllers === nothing ||
        selected_controllers((operation.controller,), controllers) ==
        (operation.controller,) ||
        throw(ArgumentError("resume selection differs from the singular recovery scope"))
    coordinator = operation.coordinator
    coordinator.failure === nothing && state(coordinator) === :Holding ||
        throw(ArgumentError("resume requires this operation's verified Holding state"))
    try
        running!(operation.channel; deadline, check)
        before = snapshot!(operation; deadline, check)
        wait_started = operation.channel.last_at_ns::Int64
        while true
            sample_cycle!(operation)
            require_open(before)
            require_scope(operation, before)
            before.recovery_state === :applied && before.inhibited ||
                throw(ControlClient.UnknownOutcome("held recovery inhibition changed"))
            fresh_reference(operation, before, operation.reference_sequence) && break
            fresh_within(
                Clocks.time_nanos(coordinator.clock), wait_started, coordinator.timeout_ns
            ) || throw(ControlClient.UnknownOutcome("fresh held reference did not arrive"))
            pause_control!(operation; deadline, check)
            before = snapshot!(operation; deadline, check)
        end
        observe_reference!(
            coordinator,
            ReferenceObservation(
                before.owner_instance,
                coordinator.token,
                before.serial,
                before.recovery_generation,
                true,
                true,
                true,
            ),
        )
        release = request_close!(coordinator, before.owner_instance, coordinator.token)
        reply = write_property!(
            operation,
            RECOVERY_PREFIX * "release-token",
            RecoveryRunner.RunnerScalar(:long, Int64(release.generation));
            deadline,
            check,
        )
        virtual_generation = generation_for(reply, RECOVERY_NODE)
        virtual_generation > before.requested_generation ||
            throw(ArgumentError("release transaction did not advance"))
        snapshot = snapshot!(operation; deadline, check)
        while state(coordinator) === :Releasing
            sample_cycle!(operation)
            require_open(snapshot)
            require_scope(operation, snapshot)
            snapshot.requested_generation == virtual_generation &&
            snapshot.active_generation <= virtual_generation || throw(
                ControlClient.UnknownOutcome("release transaction generation changed")
            )
            if snapshot.recovery_state === :released &&
                snapshot.active_generation == virtual_generation
                snapshot.release_token == coordinator.recovery_generation ||
                    throw(ControlClient.UnknownOutcome("release generation changed"))
                if !fresh_reference(operation, snapshot, before.source_sequence)
                    pause_control!(operation; deadline, check)
                    snapshot = snapshot!(operation; deadline, check)
                    continue
                end
                close = observe_release!(
                    coordinator,
                    ReleaseObservation(
                        snapshot.owner_instance,
                        coordinator.token,
                        snapshot.serial,
                        snapshot.recovery_generation,
                        !snapshot.inhibited,
                        closed(snapshot),
                        fresh_reference(operation, snapshot, before.source_sequence),
                        true,
                        true,
                    ),
                )
                close === nothing &&
                    throw(ControlClient.UnknownOutcome("release prerequisites changed"))
                reply = write_property!(
                    operation,
                    operation.controller * ":closed",
                    RecoveryRunner.RunnerScalar(:bool, true);
                    deadline,
                    check,
                )
                staged!(coordinator, close, generation_for(reply, operation.controller))
            else
                pause_control!(operation; deadline, check)
            end
            snapshot = snapshot!(operation; deadline, check)
        end
        while state(coordinator) === :Closing
            sample_cycle!(operation)
            require_scope(operation, snapshot)
            snapshot.recovery_state === :released &&
            !snapshot.inhibited &&
            snapshot.release_token == coordinator.recovery_generation &&
            snapshot.requested_generation ==
            snapshot.active_generation ==
            virtual_generation || throw(
                ControlClient.UnknownOutcome(
                    "recovery release changed during close adoption"
                ),
            )
            observe_loop!(coordinator, snapshot)
            state(coordinator) === :Closed && return operation
            pause_control!(operation; deadline, check)
            snapshot = snapshot!(operation; deadline, check)
        end
        throw(ControlClient.UnknownOutcome("close adoption is unverified"))
    catch error
        throw(recovery_error(operation, error))
    end
end

include("recovery_controllers.jl")
