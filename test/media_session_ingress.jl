module MediaSessionIngressTests
using Test, PipeWireAO, PipeWireAORTC
import Clocks
import PipeWireAORTC: ControlCodec, ControlClient, RunnerCodec, SessionCodec
module Session
import PipeWireAORTC.MediaSession: Identity, QUIT_OPERATION
include(joinpath(@__DIR__, "..", "src", "media_session", "ingress.jl"))
end
const I = Session.Ingress
const S = PipeWireAORTC.MediaSession
const C = ControlCodec
const R = RunnerCodec
const SPA = PipeWireAO.SPA
const CONTROLLER = C.ControllerIdentity(UInt32(11), UInt64(12), Int64(13))
const FACTS = I.Controller(S.Identity(11, 12, 13, 14), "client")
str(values::Pod...) = SPA.Struct(Pod[values...])
function select_actions(::Type{T}, actions) where {T}
    selected = T[]
    for action in actions
        add_selected!(selected, action)
    end
    return selected
end
add_selected!(selected::Vector{T}, action::T) where {T} = (push!(selected, action); nothing)
add_selected!(selected, action) = nothing
function gate()
    clock = Clocks.CachedNanoClock(Int64(10_000_000_000))
    g = I.Gate(17; clock, owner_pid = 19)
    @test length(I.take_actions!(g)) == 1
    I.controllers!(g, [FACTS])
    @test length(I.take_actions!(g)) == 1
    return g, clock
end
function request(
    token,
    operation = :groups;
    budget = Int64(5_000_000_000),
    controller = CONTROLLER,
    endpoint = Int64(17),
)
    command = R.RunnerCommand(operation)
    return R.encode_request(
        C.RequestHeader(
            controller, endpoint, Int64(token), R.operation_id(command), budget
        ),
        command,
    )
end
function write_request(token; budget = Int64(5_000_000_000), value = Int32(1))
    command = R.RunnerCommand(
        :properties_set, "graph", Dict("algorithm:gain" => R.RunnerScalar(:int, value))
    )
    return R.encode_request(
        C.RequestHeader(CONTROLLER, Int64(17), Int64(token), UInt32(13), budget), command
    )
end
function reply(ticket; failure = false, quit = false)
    header = C.ReplyHeader(
        ticket.header.controller,
        Int64(17),
        ticket.header.token,
        ticket.header.operation,
        Int32(failure ? -5 : 0),
    )
    payload = if failure
        str(Pod("session"), Pod("cancelled"), Pod(SPA.Id(UInt32(3))))
    elseif quit
        str(Pod(SPA.Id(UInt32(1))), Pod(SPA.Id(UInt32(1))), Pod(str(Pod(true))))
    elseif ticket.header.operation == 13
        str(
            Pod(SPA.Id(UInt32(3))),
            Pod(SPA.Id(UInt32(6))),
            Pod(str(Pod("graph"), Pod(str()), Pod(false))),
        )
    elseif ticket.header.operation == 14
        str(
            Pod(SPA.Id(UInt32(3))),
            Pod(SPA.Id(UInt32(6))),
            Pod(str(Pod("graph"), Pod("matrix"), Pod(nothing), Pod(false))),
        )
    else
        str(Pod(SPA.Id(UInt32(3))), Pod(SPA.Id(UInt32(2))), Pod(str(Pod(str()))))
    end
    C.encode_completion(header, payload; endpoint = :lifecycle)
end
function admit!(g, pod; received = Int64(10_000_000_000))
    I.receive!(g, pod, received)
    return I.take_actions!(g)
end
rejection(g) = first(C.decode_rejection(g.rejection; endpoint = :lifecycle))
completion(g) = first(C.decode_completion(g.completion; endpoint = :lifecycle))
@testset "pure ingress validation and retained terminal records" begin
    g, clock = gate()
    initial = g.completion
    actions = admit!(g, nothing)
    @test rejection(g).controller === nothing && rejection(g).result == -22
    @test g.completion == initial
    @test isempty(select_actions(I.DispatchRequest, actions))
    @test rejection(g).operation == 0
    @test isempty(
        select_actions(I.DispatchRequest, admit!(g, request(1; endpoint = Int64(18))))
    )
    @test rejection(g).result == -116
    actions = admit!(g, request(1))
    ticket = only(select_actions(I.DispatchRequest, actions)).ticket
    @test ticket.controller == FACTS.identity
    @test ticket.deadline == Int64(15_000_000_000)
    @test g.last_token == 1
    @test isempty(select_actions(I.DispatchRequest, admit!(g, request(1))))
    @test length(select_actions(I.PublishRecords, admit!(g, request(1)))) == 1
    @test isempty(select_actions(I.DispatchRequest, admit!(g, request(2))))
    @test rejection(g).result == -16
    @test g.pending === ticket
    I.complete!(g, ticket, reply(ticket))
    @test length(select_actions(I.PublishRecords, I.take_actions!(g))) == 1
    @test g.pending === nothing && completion(g).token == 1
    terminal = g.completion
    @test isempty(select_actions(I.DispatchRequest, admit!(g, request(1))))
    @test g.completion == terminal
    admit!(g, request(1; budget = Int64(4_000_000_000)))
    @test rejection(g).result == -116
    @test g.completion == terminal
    admit!(g, request(2; budget = Int64(60_000_000_001)))
    @test rejection(g).result == -22
    @test rejection(g).controller === nothing
    Clocks.update!(clock, Int64(20_000_000_000))
    admit!(g, request(2); received = Int64(10_000_000_000))
    @test rejection(g).result == -110
    @test g.last_token == 1
    I.state!(g, R.Fault)
    @test length(select_actions(I.PublishRecords, I.take_actions!(g))) == 1
    @test_throws MethodError I.state!(g, UInt32(6))
end
@testset "controller proof and sticky retirement" begin
    g, _ = gate()
    I.controllers!(g, [I.Controller(FACTS.identity, "changed")])
    I.take_actions!(g)
    admit!(g, request(1))
    @test rejection(g).result == -116
    I.controllers!(g, [FACTS])
    I.take_actions!(g)
    @test isempty(select_actions(I.DispatchRequest, admit!(g, request(1))))
    @test rejection(g).result == -116
    g, _ = gate()
    I.controllers!(g, [I.Controller(FACTS.identity, "client"; input_ports = 1)])
    I.take_actions!(g)
    admit!(g, request(1))
    @test rejection(g).result == -116
    for flag in (:full_info, :bound)
        invalid =
            flag === :full_info ?
            I.Controller(FACTS.identity, "client"; full_info = false) :
            I.Controller(FACTS.identity, "client"; bound = false)
        g, _ = gate()
        I.controllers!(g, [invalid])
        I.take_actions!(g)
        admit!(g, request(1))
        @test rejection(g).result == -116
    end
    g, _ = gate()
    I.controllers!(g, I.Controller[])
    I.take_actions!(g)
    I.controllers!(g, [FACTS])
    I.take_actions!(g)
    admit!(g, request(1))
    @test rejection(g).result == -116
    I.controller_removed!(g, FACTS.identity.global_id, FACTS.identity.serial + 1)
    I.take_actions!(g)
    @test length(g.controllers) == 1
    I.controller_removed!(g, FACTS.identity.global_id, FACTS.identity.serial)
    I.take_actions!(g)
    @test isempty(g.controllers)
    @test_throws ArgumentError I.controllers!(g, fill(FACTS, 33))
end
@testset "receipt budget and dispatched controller loss" begin
    g, clock = gate()
    ticket = only(
        select_actions(
            I.DispatchRequest, admit!(g, request(1); received = Int64(8_000_000_000))
        ),
    ).ticket
    @test ticket.deadline == Int64(13_000_000_000)
    Clocks.update!(clock, Int64(13_000_000_000))
    I.tick!(g)
    actions = I.take_actions!(g)
    @test length(select_actions(I.AuthorityFailed, actions)) == 1
    @test completion(g).result == -5
    previous = g.completion
    I.complete!(g, ticket, reply(ticket))
    I.take_actions!(g)
    @test g.completion == previous
    g, _ = gate()
    only(select_actions(I.DispatchRequest, admit!(g, request(1))))
    I.controllers!(g, I.Controller[])
    @test length(select_actions(I.AuthorityFailed, I.take_actions!(g))) == 1
    @test completion(g).result == -5
end
@testset "property and parameter changes proceed without persistence" begin
    parameter = R.RunnerCommand(
        :parameter, "graph", "matrix", "F32_LE", UInt32[2, 2], "schema", "/tmp/parameter"
    )
    header = C.RequestHeader(
        CONTROLLER, Int64(17), Int64(1), R.operation_id(parameter), Int64(5_000_000_000)
    )
    for pod in (write_request(1), R.encode_request(header, parameter))
        g, _ = gate()
        initial = g.completion
        actions = admit!(g, pod)
        ticket = only(select_actions(I.DispatchRequest, actions)).ticket
        @test g.pending === ticket
        @test g.completion == initial
        @test isempty(select_actions(I.PublishRecords, actions))
        I.complete!(g, ticket, reply(ticket))
        @test length(select_actions(I.PublishRecords, I.take_actions!(g))) == 1
        @test completion(g).result == 0 && g.pending === nothing
        result = R.decode_completion(g.completion).result
        @test result.outcome == R.Submitted
        @test !result.details.active_adoption_observed
        terminal = g.completion
        I.complete!(g, ticket, reply(ticket; failure = true))
        @test isempty(I.take_actions!(g)) && g.completion == terminal
    end
end
@testset "Quit supersedes dispatched work without overwriting its reply" begin
    for quit_first in (false, true)
        g, _ = gate()
        old = only(select_actions(I.DispatchRequest, admit!(g, write_request(1)))).ticket
        actions = admit!(g, request(2, :quit))
        quit = only(select_actions(I.DispatchRequest, actions)).ticket
        @test g.pending === quit && g.retired === old
        admit!(g, request(3))
        @test rejection(g).result == -108
        if quit_first
            I.complete!(g, quit, reply(quit; quit = true); terminal = true)
            I.take_actions!(g)
            @test completion(g).token == 2 && g.retired === old
            I.complete!(g, old, reply(old; failure = true); unknown = true)
        else
            I.complete!(g, old, reply(old; failure = true); unknown = true)
            I.take_actions!(g)
            @test g.pending === quit && g.retired === nothing
            I.complete!(g, quit, reply(quit; quit = true); terminal = true)
        end
        I.take_actions!(g)
        @test completion(g).token == 2
        @test g.pending === nothing && g.retired === nothing
        @test isempty(select_actions(I.DispatchRequest, admit!(g, request(2, :quit))))
    end
end
@testset "administrative payloads retain exact public arity" begin
    g, _ = gate()
    header = C.RequestHeader(
        CONTROLLER, Int64(17), Int64(1), UInt32(15), Int64(5_000_000_000)
    )
    admit!(g, C.encode_request(header, str(Pod(true))))
    @test rejection(g).result == -22 && rejection(g).controller === nothing
    actions = admit!(g, C.encode_request(header, str()))
    @test only(select_actions(I.DispatchRequest, actions)).ticket.command ===
        SessionCodec.WarmupCommand()
end
@testset "bounded controller evidence and request output" begin
    g = I.Gate(17; clock = Clocks.CachedNanoClock(Int64(10_000_000_000)), owner_pid = 19)
    I.take_actions!(g)
    rows = [
        I.Controller(S.Identity(i, i + 100, i + 200, i + 300), "client-$i") for i in 1:32
    ]
    I.controllers!(g, rows)
    publication = only(select_actions(I.PublishRecords, I.take_actions!(g)))
    fields = Dict(SPA.Props(publication.capability).values)
    @test length(
        pod_value(SPA.Struct, fields["pipewireao.rtc.session.controllers"]).values
    ) == 32
    @test sizeof(publication.capability) <= 64 * 1024
    I.controllers!(g, I.Controller[])
    I.take_actions!(g)
    I.controllers!(g, [I.Controller(S.Identity(33, 133, 233, 333), "new-client")])
    publication = only(select_actions(I.PublishRecords, I.take_actions!(g)))
    fields = Dict(SPA.Props(publication.capability).values)
    @test isempty(
        pod_value(SPA.Struct, fields["pipewireao.rtc.session.controllers"]).values
    )
    @test length(g.controllers) == 32
    I.controller_removed!(g, UInt32(1), UInt64(101))
    I.take_actions!(g)
    I.controllers!(g, [I.Controller(S.Identity(33, 133, 233, 333), "new-client")])
    publication = only(select_actions(I.PublishRecords, I.take_actions!(g)))
    fields = Dict(SPA.Props(publication.capability).values)
    @test length(
        pod_value(SPA.Struct, fields["pipewireao.rtc.session.controllers"]).values
    ) == 1
    @test length(g.controllers) == 32
    # Undrained output is bounded even when callers ignore the drain contract.
    for _ in 1:I.MAX_ACTIONS
        I.state!(g, R.Offline)
    end
    @test_throws ArgumentError I.state!(g, R.Offline)
    @test length(g.actions) == I.MAX_ACTIONS
end
@testset "native removal proof permits bounded sequential clients" begin
    g = I.Gate(17; clock = Clocks.CachedNanoClock(Int64(10_000_000_000)), owner_pid = 19)
    I.take_actions!(g)
    for index in 1:40
        facts = I.Controller(
            S.Identity(index, index + 100, index + 200, index + 300), "client-$index"
        )
        I.controllers!(g, [facts])
        I.take_actions!(g)
        controller = C.ControllerIdentity(
            facts.identity.global_id, facts.identity.serial, Int64(facts.identity.instance)
        )
        ticket =
            only(select_actions(I.DispatchRequest, admit!(g, request(index; controller)))).ticket
        I.complete!(g, ticket, reply(ticket))
        I.take_actions!(g)
        @test completion(g).token == index
        I.controller_removed!(g, facts.identity.global_id, facts.identity.serial)
        I.take_actions!(g)
        @test isempty(g.controllers)
    end
end
@testset "unknown success cannot publish a successful scientific claim" begin
    g, _ = gate()
    ticket = only(select_actions(I.DispatchRequest, admit!(g, write_request(1)))).ticket
    I.complete!(g, ticket, reply(ticket); unknown = true)
    @test length(select_actions(I.PublishRecords, I.take_actions!(g))) == 1
    @test completion(g).result == -5
    @test occursin("outcome unknown", R.decode_completion(g.completion).error.message)
end
@testset "late or expired mutations cannot become successful" begin
    for cause in (:expiry, :controller_loss)
        g, clock = gate()
        ticket = only(select_actions(I.DispatchRequest, admit!(g, write_request(1)))).ticket
        if cause === :expiry
            Clocks.update!(clock, ticket.deadline)
            I.tick!(g)
        else
            I.controllers!(g, I.Controller[])
        end
        actions = I.take_actions!(g)
        @test length(select_actions(I.AuthorityFailed, actions)) == 1
        @test completion(g).result == -5 && g.pending === nothing
        previous = g.completion
        I.complete!(g, ticket, reply(ticket))
        @test isempty(I.take_actions!(g)) && g.completion == previous
    end
    g, clock = gate()
    Clocks.advance!(clock, Int64(5_000_000_000))
    actions = admit!(g, write_request(1))
    @test isempty(select_actions(I.DispatchRequest, actions))
    @test rejection(g).result == -110 && g.pending === nothing
end

@testset "signed nanosecond receipts retain exact boundaries" begin
    for origin in (Int64(-10_000_000_000), (Int64(1) << 53) + 37)
        clock = Clocks.CachedNanoClock(origin)
        g = I.Gate(17; clock, owner_pid = 19)
        I.take_actions!(g)
        I.controllers!(g, [FACTS])
        I.take_actions!(g)
        actions = admit!(g, request(1; budget = Int64(1)); received = origin)
        ticket = only(select_actions(I.DispatchRequest, actions)).ticket
        @test ticket.deadline === origin + Int64(1)
        I.tick!(g)
        @test isempty(I.take_actions!(g))
        Clocks.advance!(clock, Int64(1))
        I.tick!(g)
        @test length(select_actions(I.AuthorityFailed, I.take_actions!(g))) == 1
        @test completion(g).result == -5
    end
    clock = Clocks.CachedNanoClock(typemax(Int64) - 1)
    g = I.Gate(17; clock, owner_pid = 19)
    I.take_actions!(g)
    I.controllers!(g, [FACTS])
    I.take_actions!(g)
    actions = admit!(g, request(1; budget = Int64(2)); received = typemax(Int64) - 1)
    @test isempty(select_actions(I.DispatchRequest, actions))
    @test rejection(g).result == -22 && rejection(g).controller === nothing
    @test g.pending === nothing && g.last_token == 0
    @test_throws MethodError I.receive!(g, request(1), 10.0)
    @test_throws TypeError I.Gate(17; clock = () -> Int64(0))
end

@testset "canonical lifecycle and administrative codec interfaces" begin
    g, _ = gate()
    @test g.lifecycle === R.Offline
    I.state!(g, R.Configuring)
    publication = only(select_actions(I.PublishRecords, I.take_actions!(g)))
    fields = Dict(SPA.Props(publication.capability).values)
    @test pod_value(SPA.Id, fields["pipewireao.rtc.session.lifecycle"]).value ==
        UInt32(R.Configuring)
    admit!(g, nothing)
    @test SessionCodec.decode_rejection(g.rejection).lifecycle === R.Configuring
    header = C.RequestHeader(
        CONTROLLER,
        Int64(17),
        Int64(1),
        SessionCodec.operation_id(SessionCodec.AdmitCommand()),
        Int64(5_000_000_000),
    )
    actions = admit!(g, SessionCodec.encode_request(header, SessionCodec.AdmitCommand()))
    @test only(select_actions(I.DispatchRequest, actions)).ticket.command ===
        SessionCodec.AdmitCommand()
    @test I.QUIT_OPERATION === S.QUIT_OPERATION
end
end
