# Shared scripted native transport. Including test modules supply CR, Runner,
# Envelope and Test; this helper owns no production implementation.
mutable struct ScriptedTransport <: CR.RecoveryTransport
    token::Int64
    now_ns::UInt64
    instance::Int64
    owner::Int64
    mode::Symbol
    closed::Bool
    requested::Int64
    active::Int64
    target_closed::Bool
    recovery_token::Int64
    release_token::Int64
    virtual_requested::Int64
    virtual_active::Int64
    recovery_generation::Int64
    recovery_state::Symbol
    inhibited::Bool
    source_sequence::Int64
    source_ns::Int64
    phase_polls::Int
    writes::Vector{Pair{String,Runner.RunnerScalar}}
    retained_correction::Float32
    competing_close_attempts::Int
    competing_close_accepted::Int
    resurrected_correction::Bool
end
ScriptedTransport(; mode=:normal) = ScriptedTransport(0, UInt64(1_000_000_000),
    912, 501, mode, true, 3, 3, true, 7, 0, 8, 8, 2, :idle, false,
    40, 1_000_000_000, 0, Pair{String,Runner.RunnerScalar}[], 0.8f0, 0, 0, false)
CR.transport_instance(t::ScriptedTransport) = t.instance
CR.transport_initial_token(::ScriptedTransport) = Int64(0)
CR.transport_clock_ns(t::ScriptedTransport) = t.now_ns
function CR.transport_pause!(t::ScriptedTransport, seconds::Float64)
    t.now_ns += round(UInt64, seconds * 1e9)
    return nothing
end
function result(t, ::Runner.RunnerCommand{O}, details; outcome=Runner.Observed) where {O}
    endpoint = t.mode === :wrong_session && t.recovery_state !== :idle ? t.instance + 1 : t.instance
    token = t.mode === :cached_reply && t.recovery_state !== :idle ? t.token - 1 : t.token
    header = Envelope.ReplyHeader(Envelope.ControllerIdentity(UInt32(1), UInt64(2), Int64(3)),
        endpoint, token, Runner.operation_id(Runner.RunnerCommand(O)), Int32(0))
    lifecycle = t.mode === :stopped_before_close && t.recovery_state === :released && O === :status ?
        Runner.Ready : Runner.Running
    return Runner.Completion(header, lifecycle,
        Runner.RunnerResult{O,typeof(details)}(outcome, details), nothing)
end
function CR.request_native!(t::ScriptedTransport, command::Runner.RunnerCommand;
        deadline::Float64, check)
    check()
    t.now_ns += UInt64(100_000)
    t.token += 1
    return respond!(t, command)
end
function respond!(t, command::Runner.RunnerCommand{:status})
    slow_open = t.mode === :slow_open_status && t.recovery_state === :idle && t.phase_polls > 0
    slow_close = t.mode === :slow_close_status && t.recovery_state === :released
    if slow_open || slow_close
        # Readiness succeeds after the phase's 100 ms budget, while the caller's
        # absolute deadline still has time. This must not authorize a late write.
        t.now_ns += UInt64(200_000_000)
    end
    return result(t, command, (; running=true))
end
function respond!(t, command::Runner.RunnerCommand{:properties_set})
    graph, properties = command.args
    name, value = only(properties)
    push!(t.writes, name => value)
    if t.mode === :native_error
        header = Envelope.ReplyHeader(Envelope.ControllerIdentity(UInt32(1), UInt64(2), Int64(3)),
            t.instance, t.token, Runner.operation_id(command), Int32(-22))
        return Runner.Completion(header, Runner.Running, nothing,
            Runner.RunnerError("properties", "owner rejected update"))
    end
    node, requested, active = if name == "correction:closed"
        t.target_closed = value.value::Bool
        t.requested += 1
        t.phase_polls = 0
        ("correction", t.requested, t.active)
    elseif name == "pipewireao-recovery:request-token"
        t.recovery_token = value.value::Int64
        t.virtual_requested += 1
        t.recovery_generation += 1
        t.target_closed = false
        t.requested += 1 # same-false recovery-open boundary is a real generation
        t.recovery_state = :pending
        t.inhibited = true
        t.phase_polls = 0
        ("pipewireao-recovery", t.virtual_requested, t.virtual_active)
    elseif name == "pipewireao-recovery:release-token"
        t.release_token = value.value::Int64
        t.virtual_requested += 1
        t.recovery_state = :release_pending
        t.phase_polls = 0
        ("pipewireao-recovery", t.virtual_requested, t.virtual_active)
    else
        error("unexpected property")
    end
    if t.mode === :competing_close && length(t.writes) == 1
        # The old ordinary-open path first adopts at its callback, freeing
        # the control slot while retaining correction history. A second client
        # may then close before recovery staging. The atomic recovery path is
        # tested earlier, before its first callback, with inhibition installed.
        if name == "correction:closed"
            t.active = t.requested
            t.closed = t.target_closed
        end
        t.competing_close_attempts += 1
        if !t.inhibited && t.requested == t.active && t.virtual_requested == t.virtual_active
            t.competing_close_accepted += 1
            t.target_closed = t.closed = true
            t.requested += 1
            t.active = t.requested
            t.resurrected_correction |= !iszero(t.retained_correction)
        end
    end
    generations = [(; node, requested, active)]
    return result(t, command, (; graph, generations, active_adoption_observed=false);
        outcome=Runner.Submitted)
end
scalar(value::Bool) = Runner.RunnerScalar(:bool, value)
scalar(value::Int32) = Runner.RunnerScalar(:int, value)
scalar(value::Int64) = Runner.RunnerScalar(:long, value)
scalar(value::String) = Runner.RunnerScalar(:string, value)
function respond!(t, command::Runner.RunnerCommand{:properties})
    t.phase_polls += 1
    if t.recovery_state === :pending && t.phase_polls >= (t.mode === :immediate_application ? 1 : 2)
        t.virtual_active = t.virtual_requested
        t.active = t.requested
        t.closed = false
        t.retained_correction = 0f0
        t.recovery_state = t.mode === :unknown ? :unknown : :applied
    elseif t.recovery_state === :release_pending && t.phase_polls >= 2
        t.virtual_active = t.virtual_requested
        t.recovery_state = t.mode === :release_refused ? :release_refused : :released
        t.inhibited = t.mode === :release_refused
    elseif t.recovery_state === :idle && t.requested != t.active && t.phase_polls >= 2
        t.active = t.requested
        t.closed = t.target_closed
    elseif t.recovery_state === :released && t.requested != t.active && t.phase_polls >= 2
        t.active = t.requested
        t.closed = t.target_closed
    end
    reference = t.recovery_state in (:applied, :released) && t.phase_polls >= 3 && t.mode !== :stall
    frozen = t.mode === :frozen_source ||
        (t.mode === :frozen_after_release && t.recovery_state === :released)
    if reference && !frozen
        t.source_sequence += 1
        t.source_ns = Int64(t.now_ns)
    end
    t.mode === :expired_reference && (t.source_ns = Int64(t.now_ns) - 100_000_000)
    owner = t.mode === :wrong_owner && t.recovery_state !== :idle ? t.owner + 1 : t.owner
    loop_state = t.requested == t.active ? (t.closed ? "Closed" : "Open") :
        (t.target_closed ? "Closing" : "Opening")
    release_token = t.mode === :wrong_release_token && t.recovery_state === :released ?
        t.release_token + 1 : t.release_token
    properties = Dict{String,Runner.RunnerScalar}(
        "correction:closed" => scalar(t.closed),
        "correction:requested-generation" => scalar(t.requested),
        "correction:active-generation" => scalar(t.active),
        "pipewireao.correction-control.owner-instance" => scalar(owner),
        "pipewireao.correction-control.correction:closed.state" => scalar(loop_state),
        "pipewireao.correction-control.correction:closed.fault" => scalar(""),
        "pipewireao.correction-control.correction:closed.requested" => scalar(t.target_closed),
        "pipewireao-recovery:version" => scalar(Int32(1)),
        "pipewireao-recovery:controller" => scalar("correction"),
        "pipewireao-recovery:request-token" => scalar(t.recovery_token),
        "pipewireao-recovery:release-token" => scalar(release_token),
        "pipewireao-recovery:requested-generation" => scalar(t.virtual_requested),
        "pipewireao-recovery:active-generation" => scalar(t.virtual_active),
        # Native scientific generation stays previous until scope adoption.
        "pipewireao-recovery:recovery-generation" => scalar(t.recovery_state === :pending ?
            t.recovery_generation - 1 : t.recovery_generation),
        "pipewireao-recovery:state" => scalar(string(t.recovery_state)),
        "pipewireao-recovery:closure-inhibited" => scalar(t.inhibited),
        "pipewireao-recovery:reference-reached" => scalar(reference),
        "pipewireao-recovery:observation-sequence" => scalar(t.source_sequence),
        "pipewireao-recovery:observation-monotonic-nanoseconds" => scalar(t.source_ns),
        "pipewireao-recovery:reference-timeout-ms" => scalar(Int32(100)))
    return result(t, command, (; graph=only(command.args), properties))
end
writes(t, name) = filter(write -> first(write) == name, t.writes)
function failure_of(f)
    try
        f()
    catch error
        @test error isa CR.RecoveryError
        return error
    end
    error("expected protective recovery failure")
end

