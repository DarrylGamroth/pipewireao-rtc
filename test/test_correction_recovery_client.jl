module CorrectionRecoveryClientTests
using Test, PipeWireAORTC
const CR = PipeWireAORTC.CorrectionRecovery
const Runner = PipeWireAORTC.NativeRunnerCodec
const Envelope = PipeWireAORTC.NativeControlCodec
if !isdefined(CR, :Operation)
    Base.include(CR, joinpath(@__DIR__, "../src/owners/correction_recovery_client.jl"))
end

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
end
ScriptedTransport(; mode=:normal) = ScriptedTransport(0, UInt64(1_000_000_000),
    912, 501, mode, true, 3, 3, true, 7, 0, 8, 8, 2, :idle, false,
    40, 1_000_000_000, 0, Pair{String,Runner.RunnerScalar}[])
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
respond!(t, command::Runner.RunnerCommand{:status}) = result(t, command, (; running=true))
function respond!(t, command::Runner.RunnerCommand{:properties_set})
    graph, properties = command.args
    name, value = only(properties)
    push!(t.writes, name => value)
    node, requested, active = if name == "correction:closed"
        t.target_closed = value.value::Bool
        t.requested += 1
        t.phase_polls = 0
        ("correction", t.requested, t.active)
    elseif name == "pipewireao-recovery:request-token"
        t.recovery_token = value.value::Int64
        t.virtual_requested += 1
        t.recovery_generation += 1
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
    if t.recovery_state === :pending && t.phase_polls >= 2
        t.virtual_active = t.virtual_requested
        t.active = t.requested
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
        "pipewireao-recovery:recovery-generation" => scalar(t.recovery_generation),
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

@testset "Native recovery driver keeps recovery and resume explicit" begin
    t = ScriptedTransport()
    operation = CR.protective_open!(t, "science"; deadline=2.0, reason=:saturation)
    @test CR.state(operation.coordinator) === :Holding
    @test operation.coordinator.reason === :saturation
    @test operation.coordinator.recovery_generation == 3
    @test operation.coordinator.loop_generation == 5
    @test operation.request_token == 8
    @test length(writes(t, "correction:closed")) == 1
    @test only(writes(t, "correction:closed")).second.value === false
    @test length(writes(t, "pipewireao-recovery:request-token")) == 1
    @test isempty(writes(t, "pipewireao-recovery:release-token"))
    @test CR.resume!(operation; deadline=2.0) === operation
    @test CR.state(operation.coordinator) === :Closed
    @test length(writes(t, "pipewireao-recovery:release-token")) == 1
    @test only(writes(t, "pipewireao-recovery:release-token")).second.value == 3
    @test length(writes(t, "correction:closed")) == 2
    @test last(writes(t, "correction:closed")).second.value === true
    @test_throws ArgumentError CR.resume!(operation; deadline=2.0)
    @test length(writes(t, "correction:closed")) == 2
end

@testset "Missing or expired source evidence never closes or retries" begin
    for mode in (:stall, :expired_reference)
        t = ScriptedTransport(; mode)
        failure = failure_of(() -> CR.protective_open!(t, "science"; deadline=2.0))
        @test CR.state(failure.operation.coordinator) === :Unverified
        @test failure.operation.coordinator.failure === :operation_timeout
        @test length(writes(t, "pipewireao-recovery:request-token")) == 1
        @test isempty(writes(t, "pipewireao-recovery:release-token"))
        @test length(writes(t, "correction:closed")) == 1
        @test_throws ArgumentError CR.resume!(failure.operation; deadline=2.0)
        @test length(writes(t, "correction:closed")) == 1
    end
end

@testset "Native owner and outcome failures latch without replay" begin
    for mode in (:wrong_owner, :wrong_session, :unknown, :cached_reply)
        t = ScriptedTransport(; mode)
        failure = failure_of(() -> CR.protective_open!(t, "science"; deadline=2.0))
        @test CR.state(failure.operation.coordinator) === :Unverified
        @test length(writes(t, "pipewireao-recovery:request-token")) == 1
        @test length(writes(t, "correction:closed")) == 1
        @test isempty(writes(t, "pipewireao-recovery:release-token"))
    end
end

@testset "Release refusal, lost readiness and stale source prevent close" begin
    for mode in (:release_refused, :stopped_before_close, :frozen_source,
            :frozen_after_release, :wrong_release_token)
        t = ScriptedTransport()
        operation = CR.protective_open!(t, "science"; deadline=2.0)
        t.mode = mode
        failure = failure_of(() -> CR.resume!(operation; deadline=2.0))
        @test failure.operation === operation
        @test CR.state(operation.coordinator) === :Unverified
        @test length(writes(t, "correction:closed")) == 1
        @test length(writes(t, "pipewireao-recovery:release-token")) <= 1
        @test_throws ArgumentError CR.resume!(operation; deadline=2.0)
        @test length(writes(t, "correction:closed")) == 1
    end
end

@testset "Pending recovery is refused before effects" begin
    t = ScriptedTransport()
    t.recovery_state = :pending
    t.virtual_requested += 1
    @test_throws ArgumentError CR.protective_open!(t, "science"; deadline=2.0)
    @test isempty(t.writes)
end

@testset "Cancellation after submission does not replay recovery" begin
    t = ScriptedTransport()
    check = () -> isempty(writes(t, "pipewireao-recovery:request-token")) ? nothing : throw(InterruptException())
    failure = failure_of(() -> CR.protective_open!(t, "science"; deadline=2.0, check))
    @test failure.operation.coordinator.failure === :operation_cancelled
    @test CR.state(failure.operation.coordinator) === :Unverified
    @test length(writes(t, "pipewireao-recovery:request-token")) == 1
    @test length(writes(t, "correction:closed")) == 1
end
end
