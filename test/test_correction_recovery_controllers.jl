module CoupledRecoveryClientTests
using Test, PipeWireAORTC
const CR = PipeWireAORTC.CorrectionRecovery
const Runner = PipeWireAORTC.RunnerCodec
const Envelope = PipeWireAORTC.ControlCodec
include("helpers/correction_recovery_transport.jl")
include("helpers/correction_recovery_readbacks.jl")

# The shared scripted single-loop transport supplies reply fencing and global
# recovery phases. This second branch has independent adoption and first-close
# evidence; it never uses a maximum generation as a group acknowledgement.
mutable struct CoupledTransport <: CR.AbstractRecoveryTransport
    base::ScriptedTransport
    requested::Int64
    active::Int64
    closed::Bool
    target::Bool
    guarded::Tuple{Bool,Bool}
    mode::Symbol
    transactions::Vector{Vector{String}}
end
CoupledTransport(; mode = :normal) = CoupledTransport(
    ScriptedTransport(), 9, 9, false, false, (false, false), mode, Vector{String}[]
)
CR.transport_instance(t::CoupledTransport) = CR.transport_instance(t.base)
CR.transport_initial_token(t::CoupledTransport) = CR.transport_initial_token(t.base)
CR.transport_clock_ns(t::CoupledTransport) = CR.transport_clock_ns(t.base)
CR.transport_pause!(t::CoupledTransport, seconds::Float64) =
    CR.transport_pause!(t.base, seconds)
function CR.request_native!(t::CoupledTransport, command; deadline::Float64, check)
    check()
    t.base.now_ns += UInt64(100_000)
    t.base.token += 1
    return respond!(t, command)
end
respond!(t::CoupledTransport, command::Runner.RunnerCommand{:status}) =
    respond!(t.base, command)
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
            push!(
                generations,
                (;
                    node = "correction",
                    requested = t.base.requested,
                    active = t.base.active,
                ),
            )
        elseif name == "llowfs-correction:closed"
            t.requested += 1
            t.target = value.value::Bool
            push!(
                generations,
                (; node = "llowfs-correction", requested = t.requested, active = t.active),
            )
        else
            error("unexpected controller property $name")
        end
    end
    t.base.phase_polls = 0
    return result(
        t.base,
        command,
        (; graph, generations, active_adoption_observed = false);
        outcome = Runner.Submitted,
    )
end
function respond!(t::CoupledTransport, command::Runner.RunnerCommand{:properties})
    if t.base.recovery_state === :released &&
        t.base.phase_polls == 2 &&
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
    if t.base.recovery_state !== :pending &&
        t.base.phase_polls >= 2 &&
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
    properties[p*"version"] = scalar(Int32(2))
    properties[p*"controller-count"] = scalar(Int32(t.mode === :bad_count ? 17 : 2))
    properties[p*"controller-1"] = scalar("correction")
    properties[p*"controller-2"] = scalar(
        t.mode === :duplicate ? "correction" : "llowfs-correction"
    )
    properties[p*"reference-reached"] = scalar(
        properties[p*"reference-reached"].value && !t.base.closed && !t.closed
    )
    properties["llowfs-correction:closed"] = scalar(t.closed)
    properties["llowfs-correction:requested-generation"] = scalar(t.requested)
    properties["llowfs-correction:active-generation"] = scalar(t.active)
    control = "pipewireao.correction-control.llowfs-correction:closed."
    properties[control*"state"] = scalar(
        t.requested == t.active ? (t.closed ? "Closed" : "Open") :
        (t.target ? "Closing" : "Opening"),
    )
    properties[control*"fault"] = scalar("")
    properties[control*"requested"] = scalar(t.target)
    for index in 1:2
        key = p * "controller-$index-"
        ready =
            t.guarded[index] &&
            t.base.phase_polls >= 3 &&
            !(t.mode === :scc_unready && index == 1)
        properties[key*"close-guarded"] = scalar(t.guarded[index])
        properties[key*"ready"] = scalar(ready)
        properties[key*"observation-sequence"] = scalar(t.base.source_sequence)
        properties[key*"observation-monotonic-nanoseconds"] = scalar(t.base.source_ns)
    end
    return reply
end

# Version2 explicitly declares a coupled scope even when it has one controller.
struct OneControllerTransport <: CR.AbstractRecoveryTransport
    base::ScriptedTransport
end
CR.transport_instance(t::OneControllerTransport) = CR.transport_instance(t.base)
CR.transport_initial_token(t::OneControllerTransport) = CR.transport_initial_token(t.base)
CR.transport_clock_ns(t::OneControllerTransport) = CR.transport_clock_ns(t.base)
CR.transport_pause!(t::OneControllerTransport, seconds::Float64) =
    CR.transport_pause!(t.base, seconds)
function CR.request_native!(
    t::OneControllerTransport, command::Runner.RunnerCommand; deadline::Float64, check
)
    reply = CR.request_native!(t.base, command; deadline, check)
    return one_controller_reply(t, command, reply)
end
one_controller_reply(::OneControllerTransport, command, reply) = reply
function one_controller_reply(
    t::OneControllerTransport, ::Runner.RunnerCommand{:properties}, reply
)
    properties = reply.result.details.properties
    p = "pipewireao-recovery:"
    delete!(properties, p * "controller")
    properties[p*"version"] = scalar(Int32(2))
    properties[p*"controller-count"] = scalar(Int32(1))
    properties[p*"controller-1"] = scalar("correction")
    guarded = !t.base.closed && t.base.recovery_state !== :idle
    properties[p*"controller-1-close-guarded"] = scalar(guarded)
    properties[p*"controller-1-ready"] = scalar(guarded && t.base.phase_polls >= 3)
    properties[p*"controller-1-observation-sequence"] = scalar(t.base.source_sequence)
    properties[p*"controller-1-observation-monotonic-nanoseconds"] = scalar(
        t.base.source_ns
    )
    return reply
end

@testset "Coupled native recovery releases once and recloses branches independently" begin
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline = 2.0)
    @test CR.state(operation.coordinator) === :Holding
    @test operation.coordinator.loop_generation == (4, 10)
    @test operation.controller == ("correction", "llowfs-correction")
    @test !t.base.closed && !t.closed && t.base.inhibited
    for selection in (("foreign",), (), ("correction", "correction"), "correction", (1,))
        @test_throws ArgumentError CR.resume!(
            operation; controllers = selection, deadline = 2.0
        )
    end
    @test length(t.transactions) == 1
    CR.resume!(operation; controllers = ("llowfs-correction",), deadline = 2.0)
    @test CR.state(operation.coordinator) === :PartiallyClosed
    @test !t.base.closed && t.closed && !t.base.inhibited
    @test t.guarded == (true, false)
    @test operation.coordinator.loop_generation == (4, 11)
    @test t.transactions == [
        ["pipewireao-recovery:request-token"],
        ["pipewireao-recovery:release-token"],
        ["llowfs-correction:closed"],
    ]
    CR.resume!(operation; controllers = ("correction",), deadline = 2.0)
    @test CR.state(operation.coordinator) === :Closed
    @test t.base.closed && t.closed && !t.base.inhibited
    @test t.guarded == (false, false)
    @test operation.coordinator.loop_generation == (5, 11)
    @test last(t.transactions) == ["correction:closed"]
    @test count(==(["pipewireao-recovery:release-token"]), t.transactions) == 1
end

@testset "Partial close adoption and replaced owners cannot complete or retry" begin
    t = CoupledTransport(; mode = :stalled_llowfs)
    operation = CR.protective_open!(t, "science"; deadline = 2.0)
    failure = failure_of(
        () -> CR.resume!(operation; controllers = ("llowfs-correction",), deadline = 2.0)
    )
    @test CR.state(operation.coordinator) === :Unverified
    @test t.requested == 11 && t.active == 10
    @test !t.closed && !t.base.closed
    @test length(writes(t.base, "llowfs-correction:closed")) == 1
    @test_throws ArgumentError CR.resume!(
        operation; controllers = ("llowfs-correction",), deadline = 2.0
    )
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline = 2.0)
    CR.resume!(operation; controllers = ("llowfs-correction",), deadline = 2.0)
    t.base.owner += 1
    failure = failure_of(
        () -> CR.resume!(operation; controllers = ("correction",), deadline = 2.0)
    )
    @test CR.state(operation.coordinator) === :Unverified
    @test isempty(writes(t.base, "correction:closed"))
    @test length(writes(t.base, "pipewireao-recovery:release-token")) == 1
end

@testset "Coupled native recovery closes a selected group atomically" begin
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline = 2.0)
    CR.resume!(operation; deadline = 2.0)
    @test CR.state(operation.coordinator) === :Closed
    @test last(t.transactions) == ["correction:closed", "llowfs-correction:closed"]
    @test operation.coordinator.loop_generation == (5, 11)
end

@testset "Missing branch readiness never borrows the other branch's proof" begin
    t = CoupledTransport(; mode = :scc_unready)
    operation = CR.protective_open!(t, "science"; deadline = 2.0)
    CR.resume!(operation; controllers = ("llowfs-correction",), deadline = 2.0)
    failure = failure_of(
        () -> CR.resume!(operation; controllers = ("correction",), deadline = 2.0)
    )
    @test CR.state(operation.coordinator) === :Unverified
    @test !t.base.closed && t.closed
    @test isempty(writes(t.base, "correction:closed"))
    @test t.guarded == (true, false)
    @test_throws ArgumentError CR.resume!(
        operation; controllers = ("correction",), deadline = 2.0
    )
end

@testset "Malformed plural descriptors are refused before any mutation" begin
    for mode in (:bad_count, :duplicate)
        t = CoupledTransport(; mode)
        @test_throws ArgumentError CR.protective_open!(t, "science"; deadline = 2.0)
        @test isempty(t.transactions)
    end
end

@testset "Cancelling after the first subset close inhibits every remaining effect" begin
    t = CoupledTransport()
    operation = CR.protective_open!(t, "science"; deadline = 2.0)
    CR.resume!(operation; controllers = ("llowfs-correction",), deadline = 2.0)
    transactions = length(t.transactions)
    CR.cancel!(
        operation.coordinator,
        operation.coordinator.owner_instance,
        operation.coordinator.token,
    )
    @test CR.state(operation.coordinator) === :Unverified
    @test operation.coordinator.failure === :operation_cancelled
    @test_throws ArgumentError CR.resume!(
        operation; controllers = ("correction",), deadline = 2.0
    )
    @test length(t.transactions) == transactions
    @test !t.base.closed && t.closed
end

@testset "Release rejects changed selected and unselected controller generations" begin
    for mode in (:foreign_scc_open, :foreign_llowfs_open)
        t = CoupledTransport(; mode)
        operation = CR.protective_open!(t, "science"; deadline = 2.0)
        failed = try
            CR.resume!(operation; controllers = ("llowfs-correction",), deadline = 2.0)
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

@testset "Coupled native records preserve ordered independent adoption and readiness" begin
    snapshot = native_readback(owner_properties(CoupledTransport()))
    @test snapshot isa CR.AbstractLoopObservation
    @test CR.controller_scope(snapshot) isa CR.CoupledControllers{2}
    @test snapshot.readbacks isa NTuple{2,CR.ControllerReadback{CR.ControllerReadiness}}
    @test !ismutabletype(typeof(snapshot)) &&
        all(readback -> !ismutabletype(typeof(readback)), snapshot.readbacks)
    @test snapshot.controller == ("correction", "llowfs-correction")
    @test CR.controller_names(snapshot) == snapshot.controller
    @test CR.closed(snapshot) == snapshot.closed == (true, false)
    @test CR.requested_generation(snapshot) == snapshot.loop_requested == (3, 9)
    @test CR.active_generation(snapshot) == snapshot.loop_active == (3, 9)
    @test snapshot.loop_state == (:Closed, :Open)
    @test snapshot.controller_readiness ==
        map(readback -> readback.readiness, snapshot.readbacks)
    @test all(
        proof -> proof isa CR.ControllerReadiness && !ismutabletype(typeof(proof)),
        snapshot.controller_readiness,
    )
    @test all(
        proof ->
            !proof.guarded &&
            !proof.ready &&
            proof.sequence == 40 &&
            proof.timestamp_ns == 1_000_000_000,
        snapshot.controller_readiness,
    )
    @test CR.generations_match(snapshot) &&
        !CR.all_open(snapshot) &&
        !CR.all_closed(snapshot)
    @test CR.adoption_matches(snapshot)
    @test CR.requested_before(snapshot, (UInt64(4), UInt64(9)))
    @test !CR.requested_before(snapshot, (UInt64(4), UInt64(8)))
    @test CR.active_before(snapshot, (UInt64(3), UInt64(10)))
    @test CR.active_at_least(snapshot, (UInt64(3), UInt64(8)))
    @test !CR.active_at_most(snapshot, (UInt64(2), UInt64(10)))
    aliases = (
        :controller,
        :closed,
        :loop_requested,
        :loop_active,
        :loop_state,
        :controller_readiness,
    )
    @test all(in(propertynames(snapshot)), aliases)
    @test all(name -> !(name in fieldnames(typeof(snapshot))), aliases)

    reversed = replace_readbacks(
        snapshot, CR.CoupledControllers{2}(), reverse(snapshot.readbacks)
    )
    @test reversed.controller == reverse(snapshot.controller)
    @test CR.requested_generation(reversed) == reverse(CR.requested_generation(snapshot))
    @test_throws ArgumentError replace_readbacks(
        snapshot, CR.CoupledControllers{1}(), snapshot.readbacks
    )
    @test_throws ArgumentError replace_readbacks(
        snapshot,
        CR.CoupledControllers{2}(),
        (first(snapshot.readbacks), first(snapshot.readbacks)),
    )
    @test_throws ArgumentError replace_readbacks(
        snapshot, CR.SingleController(), first(snapshot.readbacks)
    )
    @test_throws ArgumentError replace_readbacks(snapshot, CR.CoupledControllers{0}(), ())
    @test_throws ArgumentError replace_readbacks(
        snapshot, CR.CoupledControllers{17}(), ntuple(_ -> first(snapshot.readbacks), 17)
    )
    invalid = CR.ControllerReadback(
        "invalid/name",
        false,
        UInt64(1),
        UInt64(1),
        :Open,
        first(snapshot.readbacks).readiness,
    )
    @test_throws ArgumentError replace_readbacks(
        snapshot, CR.CoupledControllers{1}(), (invalid,)
    )
end

@testset "An explicitly coupled singleton remains distinct from the scalar profile" begin
    transport = OneControllerTransport(ScriptedTransport())
    channel = CR.RecoveryChannel(transport, CR.transport_instance(transport), Int64(0))
    snapshot = CR.native_snapshot!(
        channel, "science"; deadline = 2.0, check = () -> nothing
    )
    singular = native_readback(owner_properties(ScriptedTransport()))
    @test CR.controller_scope(snapshot) isa CR.CoupledControllers{1}
    @test !CR.same_scope(snapshot, singular)
    @test snapshot.controller == ("correction",)
    @test CR.requested_generation(snapshot) ==
        CR.active_generation(snapshot) ==
        (UInt64(3),)
    @test CR.closed(snapshot) == (true,)
    @test snapshot.controller_readiness isa Tuple{CR.ControllerReadiness}
    operation = CR.protective_open!(transport, "science"; deadline = 2.0)
    @test CR.controller_scope(operation) isa CR.CoupledControllers{1}
    @test operation.controller == ("correction",)
    @test operation.coordinator.loop_generation == (UInt64(4),)
    @test CR.state(operation.coordinator) === :Holding
    CR.resume!(operation; controllers = ("correction",), deadline = 2.0)
    @test CR.state(operation.coordinator) === :Closed
    @test operation.coordinator.loop_generation == (UInt64(5),)
    @test length(writes(transport.base, "pipewireao-recovery:release-token")) == 1
    @test length(writes(transport.base, "correction:closed")) == 1
end

@testset "Plural descriptor validation retains native error precedence" begin
    p = "pipewireao-recovery:"
    properties = owner_properties(CoupledTransport())
    properties[p*"controller-2"] = scalar("invalid/name")
    properties["pipewireao.correction-control.correction:closed.fault"] = scalar("fault")
    failure = readback_error(() -> native_readback(properties))
    @test failure isa ArgumentError
    @test occursin("invalid recovery controller name", sprint(showerror, failure))

    properties = owner_properties(CoupledTransport())
    properties[p*"controller-2"] = scalar("correction")
    properties["pipewireao.correction-control.correction:closed.fault"] = scalar("fault")
    failure = readback_error(() -> native_readback(properties))
    @test failure isa ArgumentError
    @test occursin("duplicate recovery controllers", sprint(showerror, failure))

    properties = owner_properties(CoupledTransport())
    properties["pipewireao.correction-control.llowfs-correction:closed.state"] = scalar(
        "Unverified"
    )
    properties[p*"controller-1-ready"] = scalar(Int64(1))
    failure = readback_error(() -> native_readback(properties))
    @test failure isa PipeWireAORTC.ControlClient.UnknownOutcome
    @test occursin("adoption is unverified", sprint(showerror, failure))

    properties = owner_properties(CoupledTransport())
    properties[p*"controller-1-close-guarded"] = scalar(Int64(1))
    properties[p*"controller-1-ready"] = scalar(Int64(1))
    failure = readback_error(() -> native_readback(properties))
    @test failure isa ArgumentError
    @test occursin("controller-1-close-guarded", sprint(showerror, failure))
end
end
