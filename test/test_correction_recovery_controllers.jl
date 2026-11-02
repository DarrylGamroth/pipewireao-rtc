module CoupledRecoveryClientTests
using Test, PipeWireAORTC
const CR = PipeWireAORTC.CorrectionRecovery
const Runner = PipeWireAORTC.NativeRunnerCodec
const Envelope = PipeWireAORTC.NativeControlCodec
include("helpers/correction_recovery_transport.jl")

# The shared scripted single-loop transport supplies reply fencing and global
# recovery phases. This second branch has independent adoption and first-close
# evidence; it never uses a maximum generation as a group acknowledgement.
mutable struct CoupledTransport <: CR.RecoveryTransport
    base::ScriptedTransport
    requested::Int64
    active::Int64
    closed::Bool
    target::Bool
    guarded::Tuple{Bool,Bool}
    mode::Symbol
    transactions::Vector{Vector{String}}
end
CoupledTransport(; mode=:normal) = CoupledTransport(ScriptedTransport(), 9, 9,
    false, false, (false, false), mode, Vector{String}[])
CR.transport_instance(t::CoupledTransport) = CR.transport_instance(t.base)
CR.transport_initial_token(t::CoupledTransport) = CR.transport_initial_token(t.base)
CR.transport_clock_ns(t::CoupledTransport) = CR.transport_clock_ns(t.base)
CR.transport_pause!(t::CoupledTransport, seconds::Float64) = CR.transport_pause!(t.base, seconds)
function CR.request_native!(t::CoupledTransport, command; deadline::Float64, check)
    check()
    t.base.now_ns += UInt64(100_000)
    t.base.token += 1
    return respond!(t, command)
end
respond!(t::CoupledTransport, command::Runner.RunnerCommand{:status}) = respond!(t.base, command)
function respond!(t::CoupledTransport, command::Runner.RunnerCommand{:properties_set})
    graph, properties = command.args
    push!(t.transactions, sort!(collect(keys(properties))))
    if haskey(properties, "pipewireao-recovery:request-token")
        t.requested += 1
        t.target = false
        t.guarded = (true, true)
        return respond!(t.base, command)
    elseif haskey(properties, "pipewireao-recovery:release-token")
        return respond!(t.base, command)
    end
    generations = NamedTuple[]
    for (name, value) in properties
        push!(t.base.writes, name => value)
        if name == "correction:closed"
            t.base.requested += 1
            t.base.target_closed = value.value::Bool
            push!(generations, (; node="correction", requested=t.base.requested, active=t.base.active))
        elseif name == "llowfs-correction:closed"
            t.requested += 1
            t.target = value.value::Bool
            push!(generations, (; node="llowfs-correction", requested=t.requested, active=t.active))
        else
            error("unexpected controller property $name")
        end
    end
    t.base.phase_polls = 0
    return result(t.base, command, (; graph, generations, active_adoption_observed=false);
        outcome=Runner.Submitted)
end
function respond!(t::CoupledTransport, command::Runner.RunnerCommand{:properties})
    if t.base.recovery_state === :released && t.base.phase_polls == 2 &&
            t.mode in (:foreign_scc_open, :foreign_llowfs_open)
        if t.mode === :foreign_scc_open
            t.base.requested += 1
            t.base.active = t.base.requested
        else
            t.requested += 1
            t.active = t.requested
        end
        t.mode = :normal
    end
    reply = respond!(t.base, command)
    if t.base.recovery_state !== :pending && t.base.phase_polls >= 2 &&
            !(t.mode === :stalled_llowfs && t.target)
        t.active = t.requested
        t.closed = t.target
    end
    if t.base.recovery_state === :released
        t.guarded = (t.guarded[1] && !t.base.closed, t.guarded[2] && !t.closed)
    end
    properties = reply.result.details.properties
    p = "pipewireao-recovery:"
    delete!(properties, p * "controller")
    properties[p * "version"] = scalar(Int32(2))
    properties[p * "controller-count"] = scalar(Int32(t.mode === :bad_count ? 17 : 2))
    properties[p * "controller-1"] = scalar("correction")
    properties[p * "controller-2"] = scalar(t.mode === :duplicate ? "correction" : "llowfs-correction")
    properties[p * "reference-reached"] = scalar(properties[p * "reference-reached"].value &&
        !t.base.closed && !t.closed)
    properties["llowfs-correction:closed"] = scalar(t.closed)
    properties["llowfs-correction:requested-generation"] = scalar(t.requested)
    properties["llowfs-correction:active-generation"] = scalar(t.active)
    control = "pipewireao.correction-control.llowfs-correction:closed."
    properties[control * "state"] = scalar(t.requested == t.active ?
        (t.closed ? "Closed" : "Open") : (t.target ? "Closing" : "Opening"))
    properties[control * "fault"] = scalar("")
    properties[control * "requested"] = scalar(t.target)
    for index in 1:2
        key = p * "controller-$index-"
        ready = t.guarded[index] && t.base.phase_polls >= 3 &&
            !(t.mode === :scc_unready && index == 1)
        properties[key * "close-guarded"] = scalar(t.guarded[index])
        properties[key * "ready"] = scalar(ready)
        properties[key * "observation-sequence"] = scalar(t.base.source_sequence)
        properties[key * "observation-monotonic-nanoseconds"] = scalar(t.base.source_ns)
    end
    return reply
end

@testset "Coupled native recovery releases once and recloses branches independently" begin
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline=2.0)
    @test CR.state(operation.coordinator) === :Holding
    @test operation.coordinator.loop_generation == (4, 10)
    @test operation.controller == ("correction", "llowfs-correction")
    @test !t.base.closed && !t.closed && t.base.inhibited
    for selection in (("foreign",), (), ("correction", "correction"), "correction", (1,))
        @test_throws ArgumentError CR.resume!(operation; controllers=selection, deadline=2.0)
    end
    @test length(t.transactions) == 1
    CR.resume!(operation; controllers=("llowfs-correction",), deadline=2.0)
    @test CR.state(operation.coordinator) === :PartiallyClosed
    @test !t.base.closed && t.closed && !t.base.inhibited
    @test t.guarded == (true, false)
    @test operation.coordinator.loop_generation == (4, 11)
    @test t.transactions == [["pipewireao-recovery:request-token"],
        ["pipewireao-recovery:release-token"], ["llowfs-correction:closed"]]
    CR.resume!(operation; controllers=("correction",), deadline=2.0)
    @test CR.state(operation.coordinator) === :Closed
    @test t.base.closed && t.closed && !t.base.inhibited
    @test t.guarded == (false, false)
    @test operation.coordinator.loop_generation == (5, 11)
    @test last(t.transactions) == ["correction:closed"]
    @test count(==(["pipewireao-recovery:release-token"]), t.transactions) == 1
end

@testset "Partial close adoption and replaced owners cannot complete or retry" begin
    t = CoupledTransport(; mode=:stalled_llowfs)
    operation = CR.protective_open!(t, "science"; deadline=2.0)
    failure = failure_of(() -> CR.resume!(operation; controllers=("llowfs-correction",), deadline=2.0))
    @test CR.state(operation.coordinator) === :Unverified
    @test t.requested == 11 && t.active == 10
    @test !t.closed && !t.base.closed
    @test length(writes(t.base, "llowfs-correction:closed")) == 1
    @test_throws ArgumentError CR.resume!(operation; controllers=("llowfs-correction",), deadline=2.0)
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline=2.0)
    CR.resume!(operation; controllers=("llowfs-correction",), deadline=2.0)
    t.base.owner += 1
    failure = failure_of(() -> CR.resume!(operation; controllers=("correction",), deadline=2.0))
    @test CR.state(operation.coordinator) === :Unverified
    @test isempty(writes(t.base, "correction:closed"))
    @test length(writes(t.base, "pipewireao-recovery:release-token")) == 1
end

@testset "Coupled native recovery closes a selected group atomically" begin
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline=2.0)
    CR.resume!(operation; deadline=2.0)
    @test CR.state(operation.coordinator) === :Closed
    @test last(t.transactions) == ["correction:closed", "llowfs-correction:closed"]
    @test operation.coordinator.loop_generation == (5, 11)
end

@testset "Missing branch readiness never borrows the other branch's proof" begin
    t = CoupledTransport(; mode=:scc_unready)
    operation = CR.protective_open!(t, "science"; deadline=2.0)
    CR.resume!(operation; controllers=("llowfs-correction",), deadline=2.0)
    failure = failure_of(() -> CR.resume!(operation; controllers=("correction",), deadline=2.0))
    @test CR.state(operation.coordinator) === :Unverified
    @test !t.base.closed && t.closed
    @test isempty(writes(t.base, "correction:closed"))
    @test t.guarded == (true, false)
    @test_throws ArgumentError CR.resume!(operation; controllers=("correction",), deadline=2.0)
end

@testset "Malformed plural descriptors are refused before any mutation" begin
    for mode in (:bad_count, :duplicate)
        t = CoupledTransport(; mode)
        @test_throws ArgumentError CR.protective_open!(t, "science"; deadline=2.0)
        @test isempty(t.transactions)
    end
end

@testset "Cancelling after the first subset close inhibits every remaining effect" begin
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline=2.0)
    CR.resume!(operation; controllers=("llowfs-correction",), deadline=2.0)
    transactions = length(t.transactions)
    CR.cancel!(operation.coordinator, operation.coordinator.owner_instance, operation.coordinator.token)
    @test CR.state(operation.coordinator) === :Unverified
    @test operation.coordinator.failure === :operation_cancelled
    @test_throws ArgumentError CR.resume!(operation; controllers=("correction",), deadline=2.0)
    @test length(t.transactions) == transactions
    @test !t.base.closed && t.closed
end

@testset "Release rejects changed selected and unselected controller generations" begin
    for mode in (:foreign_scc_open, :foreign_llowfs_open)
        t = CoupledTransport(; mode)
        operation = CR.protective_open!(t, "science"; deadline=2.0)
        failed = try
            CR.resume!(operation; controllers=("llowfs-correction",), deadline=2.0)
            nothing
        catch error
            error
        end
        @test failed isa CR.RecoveryError
        @test CR.state(operation.coordinator) === :Unverified
        @test isempty(writes(t.base, "llowfs-correction:closed"))
        @test !t.base.closed && !t.closed
    end
end
end
