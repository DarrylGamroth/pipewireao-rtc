# Included inside CorrectionRecovery. This client runs on a serialized control
# task; it neither participates in frame processing nor creates another owner.
import ..NativeSessionClient
import ..NativeRunnerCodec
import ..NativeControlClient

public Operation, RecoveryError, protective_open!, resume!

const RecoveryRunner = NativeRunnerCodec
const RECOVERY_PREFIX = "pipewireao-recovery:"
const RECOVERY_NODE = "pipewireao-recovery"

"""Transport dispatch seam for bounded, correlated native-control exchanges."""
abstract type RecoveryTransport end
struct NativeRecoveryTransport{C<:NativeSessionClient.Connection} <: RecoveryTransport
    connection::C
end
transport_instance(transport::NativeRecoveryTransport) = transport.connection.selected.status.incarnation
transport_initial_token(transport::NativeRecoveryTransport) = transport.connection.selected.status.query_token
transport_clock_ns(::RecoveryTransport) = time_ns()
transport_pause!(::RecoveryTransport, seconds::Float64) = sleep(seconds)
request_native!(transport::NativeRecoveryTransport, command; deadline::Float64, check) =
    NativeSessionClient.request!(transport.connection, command; deadline, check)

mutable struct RecoveryChannel{T<:RecoveryTransport}
    const transport::T
    const instance::Int64
    reply_token::Int64
end

"""Retained connection and one recovery operation; successful protection leaves Holding.

Call `resume!` explicitly to release and close. The operation never rebinds to a
replacement graph/session. A failed operation must be reconciled externally;
calling this driver again does not replay its effects.
"""
mutable struct Operation{T,C}
    const channel::RecoveryChannel{T}
    const coordinator::C
    const graph::String
    const controller::String
    const request_token::Int64
    const virtual_generation::UInt64
    const previous_recovery_generation::UInt64
    const baseline_sequence::UInt64
    const reference_timeout_ns::UInt64
    reference_sequence::UInt64
end

"""An uncertain native operation, retaining its latched coordinator for inspection."""
struct RecoveryError{O} <: Exception
    operation::O
    message::String
end
Base.showerror(io::IO, error::RecoveryError) = print(io, "protective recovery failed: ", error.message)

struct RecoverySnapshot
    serial::UInt64
    owner_instance::Int64
    controller::String
    closed::Bool
    loop_requested::UInt64
    loop_active::UInt64
    loop_state::Symbol
    request_token::Int64
    release_token::UInt64
    requested_generation::UInt64
    active_generation::UInt64
    recovery_generation::UInt64
    recovery_state::Symbol
    inhibited::Bool
    reference_reached::Bool
    source_sequence::UInt64
    source_ns::UInt64
    reference_timeout_ns::UInt64
end

function control_check!(channel::RecoveryChannel, deadline::Float64, check)
    isfinite(deadline) || throw(ArgumentError("recovery deadline must be finite"))
    check()
    transport_clock_ns(channel.transport) / 1e9 < deadline ||
        throw(NativeControlClient.UnknownOutcome("protective recovery deadline expired"))
    return nothing
end

native_failure(::Nothing) = "native command failed or session is not Running"
native_failure(error::RecoveryRunner.RunnerError) =
    "native command failed at " * error.field * ": " * error.message

function native_reply!(channel::RecoveryChannel, command, reply::RecoveryRunner.Completion)
    reply.header.endpoint_instance == channel.instance ||
        throw(NativeControlClient.UnknownOutcome("session owner incarnation changed"))
    reply.header.operation == RecoveryRunner.operation_id(command) &&
        reply.header.token > channel.reply_token ||
        throw(NativeControlClient.UnknownOutcome("native reply is stale or uncorrelated"))
    channel.reply_token = reply.header.token
    reply.header.result == 0 && reply.result !== nothing && reply.lifecycle == RecoveryRunner.Running ||
        throw(NativeControlClient.UnknownOutcome(native_failure(reply.error)))
    return reply
end
native_reply!(::RecoveryChannel, command, reply::RecoveryRunner.Rejection) =
    throw(NativeControlClient.UnknownOutcome("native command was rejected: " * reply.error.message))

function native_request!(channel::RecoveryChannel, command; deadline::Float64, check)
    control_check!(channel, deadline, check)
    reply = request_native!(channel.transport, command; deadline, check)
    control_check!(channel, deadline, check)
    return native_reply!(channel, command, reply)
end
function running!(channel::RecoveryChannel; deadline::Float64, check)
    reply = native_request!(channel, RecoveryRunner.RunnerCommand(:status); deadline, check)
    reply.result.details.running || throw(NativeControlClient.UnknownOutcome("session stopped running"))
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

function native_snapshot!(channel::RecoveryChannel, graph::String; deadline::Float64, check)
    reply = native_request!(channel, RecoveryRunner.RunnerCommand(:properties, graph); deadline, check)
    reply.result.details.graph == graph || throw(ArgumentError("native graph readback changed"))
    properties = reply.result.details.properties
    p = RECOVERY_PREFIX
    scalar_value(properties, p * "version", :int, Int32) == 1 ||
        throw(ArgumentError("unsupported recovery property version"))
    controller = scalar_value(properties, p * "controller", :string, String)
    isempty(controller) && throw(ArgumentError("recovery controller is absent"))
    control = "pipewireao.correction-control." * controller * ":closed."
    scalar_value(properties, control * "fault", :string, String) == "" ||
        throw(NativeControlClient.UnknownOutcome("correction adoption observer has a fault"))
    loop_state = Symbol(scalar_value(properties, control * "state", :string, String))
    loop_state in (:Open, :Closed, :Opening, :Closing) ||
        throw(NativeControlClient.UnknownOutcome("correction adoption is unverified"))
    scalar_value(properties, control * "requested", :bool, Bool)
    recovery_state = Symbol(scalar_value(properties, p * "state", :string, String))
    recovery_state in (:idle, :pending, :applied, :release_pending, :released) ||
        throw(NativeControlClient.UnknownOutcome("recovery state is " * string(recovery_state)))
    timeout_ms = scalar_value(properties, p * "reference-timeout-ms", :int, Int32)
    1 <= timeout_ms <= 60_000 || throw(ArgumentError("invalid owner reference timeout"))
    request_token = scalar_value(properties, p * "request-token", :long, Int64)
    request_token >= 0 || throw(ArgumentError("negative recovery request token"))
    return RecoverySnapshot(UInt64(reply.header.token),
        scalar_value(properties, "pipewireao.correction-control.owner-instance", :long, Int64),
        controller, scalar_value(properties, controller * ":closed", :bool, Bool),
        property_long(properties, controller * ":requested-generation"),
        property_long(properties, controller * ":active-generation"), loop_state,
        request_token, property_long(properties, p * "release-token"),
        property_long(properties, p * "requested-generation"),
        property_long(properties, p * "active-generation"),
        property_long(properties, p * "recovery-generation"), recovery_state,
        scalar_value(properties, p * "closure-inhibited", :bool, Bool),
        scalar_value(properties, p * "reference-reached", :bool, Bool),
        property_long(properties, p * "observation-sequence"),
        property_long(properties, p * "observation-monotonic-nanoseconds"),
        UInt64(timeout_ms) * UInt64(1_000_000))
end

function snapshot!(operation::Operation; deadline::Float64, check)
    snapshot = native_snapshot!(operation.channel, operation.graph; deadline, check)
    snapshot.owner_instance == operation.coordinator.owner_instance &&
        snapshot.controller == operation.controller ||
        throw(NativeControlClient.UnknownOutcome("scientific graph owner or recovery controller changed"))
    return snapshot
end

function generation_for(reply::RecoveryRunner.Completion, node::String)
    matches = filter(generation -> generation.node == node, reply.result.details.generations)
    length(matches) == 1 || throw(ArgumentError("native staging lacks one exact node generation"))
    return nonnegative(only(matches).requested::Int64)
end
function write_property!(operation::Operation, name::String, value::RecoveryRunner.RunnerScalar;
        deadline::Float64, check)
    check_timeout!(operation.coordinator)
    operation.coordinator.failure === nothing ||
        throw(NativeControlClient.UnknownOutcome(string(operation.coordinator.failure)))
    phase_deadline = operation.coordinator.pending_since_ns / 1e9 + operation.coordinator.timeout_ns / 1e9
    effect_deadline = min(deadline, phase_deadline)
    running!(operation.channel; deadline=effect_deadline, check)
    # A successful readiness roundtrip can still exhaust the phase budget.
    # Recheck immediately before handing an effect to the native client.
    check_timeout!(operation.coordinator)
    operation.coordinator.failure === nothing ||
        throw(NativeControlClient.UnknownOutcome(string(operation.coordinator.failure)))
    reply = native_request!(operation.channel,
        RecoveryRunner.RunnerCommand(:properties_set, operation.graph,
            Dict{String,RecoveryRunner.RunnerScalar}(name => value)); deadline=effect_deadline, check)
    reply.result.details.graph == operation.graph || throw(ArgumentError("native staging graph changed"))
    return reply
end

function pause_control!(operation::Operation; deadline::Float64, check)
    check_timeout!(operation.coordinator)
    operation.coordinator.failure === nothing ||
        throw(NativeControlClient.UnknownOutcome(string(operation.coordinator.failure)))
    control_check!(operation.channel, deadline, check)
    remaining = deadline - transport_clock_ns(operation.channel.transport) / 1e9
    transport_pause!(operation.channel.transport, min(0.01, remaining))
    return nothing
end

loop_readback(operation::Operation, snapshot::RecoverySnapshot) =
    LoopObservation(snapshot.owner_instance, operation.coordinator.token, snapshot.serial,
        snapshot.loop_requested, snapshot.loop_active, snapshot.closed)
function require_open(snapshot::RecoverySnapshot)
    !snapshot.closed && snapshot.loop_requested == snapshot.loop_active && snapshot.loop_state === :Open ||
        throw(NativeControlClient.UnknownOutcome("controller is not coherently held open"))
    return nothing
end
function require_scope(operation::Operation, snapshot::RecoverySnapshot)
    snapshot.request_token == operation.request_token &&
        snapshot.recovery_generation == operation.coordinator.recovery_generation ||
        throw(NativeControlClient.UnknownOutcome("recovery operation identity changed"))
    return nothing
end
function fresh_reference(operation::Operation, snapshot::RecoverySnapshot, after_sequence::UInt64)
    now = transport_clock_ns(operation.channel.transport)
    return snapshot.reference_reached && snapshot.source_sequence > after_sequence &&
        snapshot.source_ns > 0 && now >= snapshot.source_ns &&
        now - snapshot.source_ns < min(operation.reference_timeout_ns, snapshot.reference_timeout_ns)
end

client_failure_reason(::InterruptException) = :operation_cancelled
client_failure_reason(error) = :native_operation_failed
function recovery_error(operation::Operation, error)
    failed!(operation.coordinator, client_failure_reason(error))
    return RecoveryError(operation, sprint(showerror, error))
end

"""Open, restore the declared scoped reference and leave correction in Holding.

Every query uses the existing absolute deadline and cancellation check. Native
request tokens identify requests; scientific generation and owner observation
sequence independently identify reference evidence. No reply cache is relabeled.
The default timeout is the graph's configured reference timeout. Command arrival
and coherence are established by the scientific owner; physical settling is not.
"""
protective_open!(connection::NativeSessionClient.Connection, graph::AbstractString; kwargs...) =
    protective_open!(NativeRecoveryTransport(connection), graph; kwargs...)
function protective_open!(transport::RecoveryTransport, graph::AbstractString;
        deadline::Float64, timeout_ms::Union{Nothing,Integer}=nothing,
        reason::Symbol=:operator, check=NativeControlClient.NO_CHECK)
    channel = RecoveryChannel(transport, transport_instance(transport), transport_initial_token(transport))
    running!(channel; deadline, check)
    initial = native_snapshot!(channel, String(graph); deadline, check)
    initial.recovery_state in (:idle, :released) && !initial.inhibited &&
        initial.requested_generation == initial.active_generation ||
        throw(ArgumentError("another recovery transaction is pending"))
    timeout = timeout_ms === nothing ? Int(initial.reference_timeout_ns ÷ UInt64(1_000_000)) : timeout_ms
    coordinator = Coordinator(initial.owner_instance; clock=() -> transport_clock_ns(transport), timeout_ms=timeout)
    initial.request_token < typemax(Int64) || throw(ArgumentError("recovery request tokens exhausted"))
    operation = Operation(channel, coordinator, String(graph), initial.controller,
        initial.request_token + 1, initial.requested_generation,
        initial.recovery_generation, initial.source_sequence,
        min(coordinator.timeout_ns, initial.reference_timeout_ns), initial.source_sequence)
    try
        qualify!(coordinator, LoopObservation(initial.owner_instance, UInt64(0), initial.serial,
            initial.loop_requested, initial.loop_active, initial.closed))
        effect = request_protection!(coordinator, initial.owner_instance, UInt64(operation.request_token); reason)
        reply = write_property!(operation, operation.controller * ":closed",
            RecoveryRunner.RunnerScalar(:bool, false); deadline, check)
        staged!(coordinator, effect, generation_for(reply, operation.controller))
        while state(coordinator) === :Opening
            snapshot = snapshot!(operation; deadline, check)
            stage = observe_loop!(coordinator, loop_readback(operation, snapshot))
            stage === nothing || return restore_reference!(operation, stage; deadline, check)
            pause_control!(operation; deadline, check)
        end
        throw(NativeControlClient.UnknownOutcome("opening did not establish a recovery stage"))
    catch error
        throw(recovery_error(operation, error))
    end
end

function restore_reference!(operation::Operation, effect::StageRecovery; deadline::Float64, check)
    coordinator = operation.coordinator
    reply = write_property!(operation, RECOVERY_PREFIX * "request-token",
        RecoveryRunner.RunnerScalar(:long, operation.request_token); deadline, check)
    virtual_generation = generation_for(reply, RECOVERY_NODE)
    virtual_generation > operation.virtual_generation || throw(ArgumentError("recovery transaction did not advance"))
    bound = false
    while state(coordinator) !== :Holding
        snapshot = snapshot!(operation; deadline, check)
        snapshot.request_token == operation.request_token ||
            throw(NativeControlClient.UnknownOutcome("recovery request token changed"))
        snapshot.requested_generation == virtual_generation && snapshot.active_generation <= virtual_generation ||
            throw(NativeControlClient.UnknownOutcome("recovery transaction generation changed"))
        if !bound && snapshot.recovery_generation > operation.previous_recovery_generation
            recovery_staged!(coordinator, effect, snapshot.recovery_generation;
                loop_generation=snapshot.loop_requested)
            bound = true
            # Give the pending recovery-open update to the coordinator, with its
            # exact native generation, before interpreting scope application.
            observe_loop!(coordinator, loop_readback(operation, snapshot))
        elseif bound && state(coordinator) === :RestoringReference
            observe_loop!(coordinator, loop_readback(operation, snapshot))
            # Scope application needs a separate authority-processed reply token.
            if snapshot.active_generation == virtual_generation && snapshot.recovery_state === :applied
                applied = snapshot!(operation; deadline, check)
                require_open(applied)
                require_scope(operation, applied)
                applied.requested_generation == applied.active_generation == virtual_generation &&
                    applied.recovery_state === :applied && applied.inhibited ||
                    throw(NativeControlClient.UnknownOutcome("recovery application changed"))
                generation = coordinator.recovery_generation
                observe_recovery!(coordinator, RecoveryObservation(applied.owner_instance,
                    coordinator.token, applied.serial, generation, generation, :applied, true))
            end
        elseif bound && state(coordinator) === :Verifying
            require_open(snapshot)
            require_scope(operation, snapshot)
            snapshot.recovery_state === :applied && snapshot.inhibited ||
                throw(NativeControlClient.UnknownOutcome("reference verification lost recovery inhibition"))
            observe_reference!(coordinator, ReferenceObservation(snapshot.owner_instance,
                coordinator.token, snapshot.serial, snapshot.recovery_generation,
                fresh_reference(operation, snapshot, operation.baseline_sequence), true, true))
            state(coordinator) === :Holding && (operation.reference_sequence = snapshot.source_sequence)
        end
        state(coordinator) === :Holding && return operation
        pause_control!(operation; deadline, check)
    end
    return operation
end

"""Explicitly resume this held operation, with fresh readiness and reference evidence.

Release and close are each sent once. A refused, uncertain or expired release
never sends CloseLoop and the coordinator remains latched for reconciliation.
"""
function resume!(operation::Operation; deadline::Float64, check=NativeControlClient.NO_CHECK)
    coordinator = operation.coordinator
    coordinator.failure === nothing && state(coordinator) === :Holding ||
        throw(ArgumentError("resume requires this operation's verified Holding state"))
    try
        running!(operation.channel; deadline, check)
        wait_started = transport_clock_ns(operation.channel.transport)
        before = snapshot!(operation; deadline, check)
        while true
            require_open(before)
            require_scope(operation, before)
            before.recovery_state === :applied && before.inhibited ||
                throw(NativeControlClient.UnknownOutcome("held recovery inhibition changed"))
            fresh_reference(operation, before, operation.reference_sequence) && break
            transport_clock_ns(operation.channel.transport) - wait_started < coordinator.timeout_ns ||
                throw(NativeControlClient.UnknownOutcome("fresh held reference did not arrive"))
            pause_control!(operation; deadline, check)
            before = snapshot!(operation; deadline, check)
        end
        observe_reference!(coordinator, ReferenceObservation(before.owner_instance,
            coordinator.token, before.serial, before.recovery_generation, true, true, true))
        release = request_close!(coordinator, before.owner_instance, coordinator.token)
        reply = write_property!(operation, RECOVERY_PREFIX * "release-token",
            RecoveryRunner.RunnerScalar(:long, Int64(release.generation)); deadline, check)
        virtual_generation = generation_for(reply, RECOVERY_NODE)
        virtual_generation > before.requested_generation || throw(ArgumentError("release transaction did not advance"))
        while state(coordinator) === :Releasing
            snapshot = snapshot!(operation; deadline, check)
            require_open(snapshot)
            require_scope(operation, snapshot)
            snapshot.requested_generation == virtual_generation && snapshot.active_generation <= virtual_generation ||
                throw(NativeControlClient.UnknownOutcome("release transaction generation changed"))
            if snapshot.recovery_state === :released && snapshot.active_generation == virtual_generation
                snapshot.release_token == coordinator.recovery_generation ||
                    throw(NativeControlClient.UnknownOutcome("release generation changed"))
                if !fresh_reference(operation, snapshot, before.source_sequence)
                    pause_control!(operation; deadline, check)
                    continue
                end
                close = observe_release!(coordinator, ReleaseObservation(snapshot.owner_instance,
                    coordinator.token, snapshot.serial, snapshot.recovery_generation, !snapshot.inhibited,
                    snapshot.closed, fresh_reference(operation, snapshot, before.source_sequence), true, true))
                close === nothing && throw(NativeControlClient.UnknownOutcome("release prerequisites changed"))
                reply = write_property!(operation, operation.controller * ":closed",
                    RecoveryRunner.RunnerScalar(:bool, true); deadline, check)
                staged!(coordinator, close, generation_for(reply, operation.controller))
            else
                pause_control!(operation; deadline, check)
            end
        end
        while state(coordinator) === :Closing
            snapshot = snapshot!(operation; deadline, check)
            require_scope(operation, snapshot)
            snapshot.recovery_state === :released && !snapshot.inhibited &&
                snapshot.release_token == coordinator.recovery_generation &&
                snapshot.requested_generation == snapshot.active_generation == virtual_generation ||
                throw(NativeControlClient.UnknownOutcome("recovery release changed during close adoption"))
            observe_loop!(coordinator, loop_readback(operation, snapshot))
            state(coordinator) === :Closed && return operation
            pause_control!(operation; deadline, check)
        end
        throw(NativeControlClient.UnknownOutcome("close adoption is unverified"))
    catch error
        throw(recovery_error(operation, error))
    end
end
