using Test
using JSON3
using Sockets

include("calibration_acquisition.jl")
include("calibration_server.jl")
const Server = CalibrationServer

# Typed synthetic acquisition evidence tests protocol/lifecycle behavior only.
# These fixtures do not qualify deployed optics, WFS processing or endpoints.
mutable struct ServerTestSession
    domain::NTuple{16,UInt8}
    generation::UInt64
    sequence::UInt64
    model_ns::UInt64
    held::Bool
    failed::Bool
    values::Vector{Float32}
    samples::Vector{Vector{Float32}}
    figure::Vector{Float32}
    adopted::Vector{Vector{Float32}}
    adoption_budgets::Vector{UInt64}
    exposure_budgets::Vector{UInt64}
    delay::Float64
    valid::Bool
    fail_adoption::Bool
    fail_exposure::Bool
    invalid_after_adoption::Bool
    validity::Vector{Bool}
end
function server_fixture(; samples=[Float32[3, 4]], delay=0.0)
    session = ServerTestSession(ntuple(UInt8, 16), 7, 0, 0, false, false,
        copy(first(samples)), samples, zeros(Float32, 2), Vector{Float32}[], UInt64[], UInt64[],
        delay, true, false, false, false, Bool[])
    owner = Server.Owner(session; normal_controller_absent=true, command_count=2,
        measurement_count=length(session.values), maximum_timeout_ns=UInt64(2_000_000_000))
    return (; session, owner)
end
Server.session_cursor(session::ServerTestSession) =
    (; domain=UInt64(1), generation=session.generation, sequence=session.sequence, model_ns=session.model_ns)
Server.session_domain(session::ServerTestSession) = session.domain
Server.session_response_values(session::ServerTestSession) = session.values
function Server.session_hold!(session::ServerTestSession)
    session.failed && error("faulted synthetic acquisition")
    session.held = true
    return Server.session_cursor(session)
end
function Server.session_release!(session::ServerTestSession)
    session.failed && error("faulted synthetic acquisition")
    session.held = false
    return nothing
end
function Server.session_fault!(session::ServerTestSession)
    session.failed = true
    session.held = true
    return nothing
end
function Server.session_adopt!(session::ServerTestSession, figure; timeout_ns)
    session.held && !session.failed || error("unavailable synthetic acquisition")
    push!(session.adoption_budgets, timeout_ns)
    session.fail_adoption && error("synthetic adoption failed")
    demanded = clamp.(figure, -10.0f0, 10.0f0)
    copyto!(session.figure, demanded)
    push!(session.adopted, copy(demanded))
    session.invalid_after_adoption && throw(Server.InvalidRequest())
    return (; cursor=Server.session_cursor(session), figure=demanded, clipped=demanded != figure)
end
struct ServerTestExposure
    identity::NamedTuple{(:domain, :generation, :sequence),Tuple{NTuple{16,UInt8},UInt64,UInt64}}
    start_ns::UInt64
    exposure_duration_nanoseconds::UInt64
end
Server.exposure_start_ns(exposure::ServerTestExposure) = Int64(exposure.start_ns)
function Server.session_acquire!(session::ServerTestSession; timeout_ns, require_valid)
    session.held && !session.failed || error("unavailable synthetic acquisition")
    push!(session.exposure_budgets, timeout_ns)
    session.fail_exposure && error("synthetic exposure failed")
    session.delay > 0 && sleep(session.delay)
    valid = isempty(session.validity) ? session.valid : session.validity[mod1(Int(session.sequence + 1), length(session.validity))]
    require_valid && !valid && error("invalid synthetic WFS response")
    session.sequence += 1
    exposure = ServerTestExposure((; domain=session.domain, generation=session.generation, sequence=session.sequence), session.model_ns, UInt64(50))
    session.model_ns += 50
    copyto!(session.values, session.samples[mod1(Int(session.sequence), length(session.samples))])
    return (; exposure, valid)
end

function server_request(action; run=UInt64(1), serial=UInt64(1), timeout_ns=UInt64(1_000_000_000))
    return Server.parse_request(JSON3.write((; version=1, run, serial, timeout_ns, action)))
end
function apply_server!(owner, action; kwargs...)
    return Server.execute!(owner, server_request(action; kwargs...))
end
function held_adopted_fixture(; kwargs...)
    fixture = server_fixture(; kwargs...)
    @test apply_server!(fixture.owner, (; kind="hold")).result.kind == "held"
    @test apply_server!(fixture.owner, (; kind="adopt", probe=0, figure=Float32[1, 2]); serial=2).result.kind == "adopted"
    return fixture
end

struct UnreadableServerTestSession
    domain::NTuple{16,UInt8}
end
Server.session_response_values(::UnreadableServerTestSession) = error("no correlated first receipt")
@testset "fresh owner construction does not read unavailable sink data" begin
    session = UnreadableServerTestSession(ntuple(UInt8, 16))
    owner = Server.Owner(session; measurement_count=376, normal_controller_absent=true)
    @test owner.measurement_count == 376
    @test owner.domain === session.domain
end

@testset "strict bounded calibration version-one requests" begin
    payload = JSON3.write((; version=1, run=1, serial=1, timeout_ns=1_000_000_000, action=(; kind="hold")))
    @test Server.parse_request(payload).serial == 1
    maximum = payload * repeat(" ", Server.MAX_REQUEST_BYTES - ncodeunits(payload) - 1)
    @test Server.parse_request(maximum).action.kind == "hold"
    for bad in (
        maximum * " ", "[]", "{}", replace(payload, "\"version\":1" => "\"version\":2"),
        replace(payload, "\"version\":1" => "\"version\":true"),
        replace(payload, "\"run\":1" => "\"run\":0"),
        replace(payload, "\"serial\":1" => "\"serial\":true"),
        replace(payload, "\"serial\":1" => "\"serial\":1.0"),
        replace(payload, "\"serial\":1" => "\"serial\":1e0"),
        replace(payload, "\"serial\":1" => "\"serial\":1,\"serial\":2"),
        replace(payload, "\"timeout_ns\":1000000000" => "\"timeout_ns\":0"),
        replace(payload, "\"timeout_ns\":1000000000" => "\"timeout_ns\":18446744073709551615"),
        replace(payload, "\"kind\":\"hold\"" => "\"kind\":\"hold\",\"extra\":1"),
        replace(payload, "\"kind\":\"hold\"" => "\"kind\":\"unknown\""),
    )
        @test_throws Server.InvalidRequest Server.parse_request(bad)
    end
    cursor = (; domain=1, generation=7, sequence=0, model_ns=0)
    for action in (
        (; kind="adopt", probe=true, figure=[1, 2]),
        (; kind="adopt", probe=0.0, figure=[1, 2]),
        (; kind="adopt", probe=0, figure=Any[true, 2]),
        (; kind="adopt", probe=0, figure=Float64[1e100, 2]),
        (; kind="settle", probe=0, after=merge(cursor, (; sequence=0.0)), rule=(; kind="immediate")),
        (; kind="settle", probe=0, after=cursor, rule=(; kind="discard_exposures", frames=1.0)),
        (; kind="settle", probe=0, after=cursor, rule=(; kind="discard_exposures", frames=0)),
        (; kind="settle", probe=0, after=cursor, rule=(; kind="model_time", duration_ns=0)),
        (; kind="collect", probe=0, after=cursor, measurements=2, frames=0),
        (; kind="restore", figure=[0, 0], rule=(; kind="immediate", extra=1)),
    )
        @test_throws Server.InvalidRequest server_request(action)
    end
    @test_throws ArgumentError Server.Owner(server_fixture().session; measurement_count=2, normal_controller_absent=false)
end

@testset "exact cursors and response intervals with Float64 averaging" begin
    (; session, owner) = held_adopted_fixture(; samples=[Float32[1e8, 3], Float32[1, 6], Float32[-1e8, 9]])
    after = Server.session_cursor(session)
    reply = apply_server!(owner, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3)
    @test reply.result.cursor == after
    @test isempty(session.exposure_budgets)
    reply = apply_server!(owner, (; kind="collect", probe=0, after, measurements=2, frames=3); serial=4)
    @test reply.run == 1 && reply.serial == 4
    @test reply.result.kind == "responses" && reply.result.valid
    @test reply.result.values == Float32[1 / 3, 6]
    @test [exposure.sequence for exposure in reply.result.exposures] == UInt64[1, 2, 3]
    @test [exposure.start_model_ns for exposure in reply.result.exposures] == UInt64[0, 50, 100]
    @test all(exposure -> exposure.domain == 1 && exposure.generation == 7 && exposure.duration_ns == 50, reply.result.exposures)
    @test owner.domain === session.domain
    @test Server.parse_request(JSON3.write((; version=1, run=1, serial=5, timeout_ns=1, action=(; kind="release")))).action.kind == "release"
    @test apply_server!(owner, (; kind="release"); serial=5).result.reason == "invalid_evidence"
    @test owner.held && session.held
    restored = apply_server!(owner, (; kind="restore", figure=Float32[0, 0], rule=(; kind="discard_exposures", frames=2)); serial=6)
    @test restored.result.kind == "restored" && !restored.result.clipped
    @test length(session.adopted) == 2 && last(session.adopted) == Float32[0, 0]
    @test session.sequence == 5 && session.model_ns == 250
    @test apply_server!(owner, (; kind="release"); serial=7).result.kind == "released"
    @test !owner.held && !session.held && owner.restored
    @test ncodeunits(Server.encode_reply(reply)) <= Server.MAX_REPLY_BYTES
end

@testset "settling consumes declared actual exposures" begin
    for (rule, count) in (((; kind="discard_exposures", frames=2), 2), ((; kind="model_time", duration_ns=120), 3))
        (; session, owner) = held_adopted_fixture()
        session.valid = false # Discarded settling samples need no valid estimator result.
        after = Server.session_cursor(session)
        reply = apply_server!(owner, (; kind="settle", probe=0, after, rule); serial=3)
        @test reply.result.kind == "settled"
        @test reply.result.cursor.sequence == count
        @test reply.result.cursor.model_ns == 50 * count
        @test length(session.exposure_budgets) == count
        @test issorted(reverse(session.exposure_budgets))
    end
end

@testset "stale, foreign, early and oversized requests have no model effects" begin
    (; session, owner) = held_adopted_fixture()
    after = Server.session_cursor(session)
    for (serial, action, run) in (
        (2, (; kind="release"), 1),
        (3, (; kind="release"), 2),
        (3, (; kind="collect", probe=0, after, measurements=2, frames=1), 1),
        (4, (; kind="settle", probe=1, after, rule=(; kind="immediate")), 1),
        (5, (; kind="settle", probe=0, after=merge(after, (; generation=UInt64(8))), rule=(; kind="immediate")), 1),
    )
        reply = apply_server!(owner, action; serial, run)
        @test reply.result.reason == "invalid_evidence"
        @test isempty(session.exposure_budgets)
        @test session.held && !session.failed
    end
    @test apply_server!(owner, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=6).result.kind == "settled"
    @test apply_server!(owner, (; kind="collect", probe=0, after, measurements=2, frames=4096); serial=7).result.reason == "invalid_evidence"
    @test isempty(session.exposure_budgets)
    @test apply_server!(owner, (; kind="release"); serial=8, timeout_ns=UInt64(2_000_000_001)).result.reason == "invalid_evidence"
    @test owner.serial == 7
end

@testset "one original request budget and failed instance restoration fencing" begin
    (; session, owner) = held_adopted_fixture(; delay=0.03)
    after = Server.session_cursor(session)
    @test apply_server!(owner, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
    reply = apply_server!(owner, (; kind="collect", probe=0, after, measurements=2, frames=4); serial=4, timeout_ns=UInt64(70_000_000))
    @test reply.result.kind == "failed" && reply.result.reason == "endpoint"
    @test owner.faulted && owner.held && session.failed && session.held
    @test 1 <= length(session.exposure_budgets) <= 3
    @test issorted(reverse(session.exposure_budgets))
    before = (length(session.adopted), session.sequence)
    @test apply_server!(owner, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=5).result.reason == "endpoint"
    @test apply_server!(owner, (; kind="release"); serial=6).result.reason == "endpoint"
    @test (length(session.adopted), session.sequence) == before
    @test !owner.restored
end

@testset "nonfinite WFS and full-domain changes fault without partial responses" begin
    for problem in (:nonfinite, :domain, :adoption)
        (; session, owner) = held_adopted_fixture()
        after = Server.session_cursor(session)
        if problem == :adoption
            session.fail_adoption = true
            reply = apply_server!(owner, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=3)
        else
            @test apply_server!(owner, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
            problem == :nonfinite && (session.samples[1][1] = NaN32)
            problem == :domain && (session.domain = ntuple(_ -> UInt8(99), 16))
            reply = apply_server!(owner, (; kind="collect", probe=0, after, measurements=2, frames=1); serial=4)
        end
        @test reply.result.kind == "failed"
        @test owner.faulted && owner.held && session.held
        @test !owner.restored
    end
end

@testset "clipping remains visible and restoration uses a new adoption" begin
    (; session, owner) = server_fixture()
    @test apply_server!(owner, (; kind="hold")).result.kind == "held"
    adopted = apply_server!(owner, (; kind="adopt", probe=0, figure=Float32[100, 2]); serial=2)
    @test adopted.result.kind == "adopted" && adopted.result.clipped
    @test adopted.result.figure == Float32[10, 2]
    @test owner.held && !owner.faulted
    restored = apply_server!(owner, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=3)
    @test restored.result.kind == "restored" && !restored.result.clipped
    @test length(session.adopted) == 2 && last(session.adopted) == Float32[0, 0]
    @test owner.restored && owner.held
    @test apply_server!(owner, (; kind="release"); serial=4).result.kind == "released"

    (; session, owner) = held_adopted_fixture()
    restored = apply_server!(owner, (; kind="restore", figure=Float32[100, 0], rule=(; kind="immediate")); serial=3)
    @test restored.result.kind == "restored" && restored.result.clipped
    @test owner.faulted && owner.held && !owner.restored
    @test apply_server!(owner, (; kind="release"); serial=4).result.reason == "endpoint"
end

@testset "FAC-R3 restoration rejection preserves or invalidates probe association" begin
    (; session, owner) = held_adopted_fixture()
    session.model_ns = UInt64(50)
    after = Server.session_cursor(session)
    @test apply_server!(owner, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
    rejected = apply_server!(owner, (; kind="restore", figure=Float32[0, 0],
        rule=(; kind="model_time", duration_ns=typemax(Int64))); serial=4)
    @test rejected.result.reason == "invalid_evidence"
    @test session.figure == Float32[1, 2]
    @test length(session.adopted) == 1
    @test owner.phase == :settled && owner.probe == 0 && !owner.faulted
    follow = apply_server!(owner, (; kind="collect", probe=0, after, measurements=2, frames=1); serial=5)
    @test follow.result.kind == "responses"
    @test session.figure == Float32[1, 2] # The still-associated probe was never replaced.
    restored = apply_server!(owner, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=6)
    @test restored.result.kind == "restored" && owner.restored

    (; session, owner) = held_adopted_fixture()
    after = Server.session_cursor(session)
    @test apply_server!(owner, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
    session.invalid_after_adoption = true
    failed = apply_server!(owner, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=4)
    @test failed.result.reason == "endpoint"
    @test session.figure == Float32[0, 0] && length(session.adopted) == 2
    @test owner.phase == :fault && owner.probe === nothing && owner.faulted
    @test owner.held && session.held && session.failed && !owner.restored
    @test apply_server!(owner, (; kind="collect", probe=0, after, measurements=2, frames=1); serial=5).result.reason == "endpoint"
    @test apply_server!(owner, (; kind="restore", figure=Float32[1, 2], rule=(; kind="immediate")); serial=6).result.reason == "endpoint"
    @test isempty(session.exposure_budgets) && length(session.adopted) == 2
end

@testset "complete invalid WFS batch remains visible and permits reference restoration" begin
    (; session, owner) = held_adopted_fixture()
    after = Server.session_cursor(session)
    @test apply_server!(owner, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
    session.validity = [true, false, true] # The final valid receipt cannot hide an earlier invalid one.
    batch = apply_server!(owner, (; kind="collect", probe=0, after, measurements=2, frames=3); serial=4)
    @test batch.result.kind == "responses"
    @test get(batch.result, :valid, true) === false
    @test length(get(batch.result, :exposures, ())) == 3
    @test get(batch.result, :values, Float32[]) == Float32[3, 4]
    @test session.sequence == 3 && session.model_ns == 150
    @test length(session.exposure_budgets) == 3
    @test !owner.faulted && !session.failed && owner.held && session.held
    # CalibrationCoordinator rejects valid=false and emits this fresh Restore;
    # it retains no accepted calibration matrix or partial response artifact.
    restored = apply_server!(owner, (; kind="restore", figure=Float32[0, 0],
        rule=(; kind="discard_exposures", frames=1)); serial=5)
    @test restored.result.kind == "restored" && !restored.result.clipped
    @test length(session.adopted) == 2 && last(session.adopted) == Float32[0, 0]
    @test owner.restored && !owner.faulted && !session.failed
    @test apply_server!(owner, (; kind="release"); serial=6).result.kind == "released"
end

function socket_reply(socket)
    return JSON3.read(Server.read_record(socket; timeout_ns=UInt64(2_000_000_000)))
end
function send_action(socket, action; serial, timeout_ns=UInt64(1_000_000_000))
    write(socket, JSON3.write((; version=1, run=1, serial, timeout_ns, action)), '\n')
    flush(socket)
    return socket_reply(socket)
end

@testset "bounded socket server interoperability and serialized control" begin
    mktempdir() do directory
        path = joinpath(directory, "calibration.sock")
        (; session, owner) = server_fixture()
        listener = listen(path) # Launcher can publish its connect ACK after this.
        services = Ref(0)
        server = @async Server.serve!(owner, listener; service_control=() -> (services[] += 1))
        client = connect(path)
        @test send_action(client, (; kind="hold"); serial=1).result.kind == "held"
        @test send_action(client, (; kind="adopt", probe=0, figure=Float32[1, 2]); serial=2).result.kind == "adopted"
        after = Server.session_cursor(session)
        @test send_action(client, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
        @test send_action(client, (; kind="collect", probe=0, after, measurements=2, frames=2); serial=4).result.kind == "responses"
        @test send_action(client, (; kind="restore", figure=Float32[0, 0], rule=(; kind="model_time", duration_ns=70)); serial=5).result.kind == "restored"
        @test send_action(client, (; kind="release"); serial=6).result.kind == "released"
        @test fetch(server) === owner
        @test services[] > 0 && !owner.faulted && !owner.held
        close(client)
    end
end

@testset "quality-invalid batch wire reply preserves full evidence and restoration" begin
    mktempdir() do directory
        (; session, owner) = server_fixture()
        session.validity = [true, false, true]
        path = joinpath(directory, "quality.sock")
        listener = listen(path)
        server = @async Server.serve!(owner, listener)
        client = connect(path)
        @test send_action(client, (; kind="hold"); serial=1).result.kind == "held"
        @test send_action(client, (; kind="adopt", probe=0, figure=Float32[1, 2]); serial=2).result.kind == "adopted"
        after = Server.session_cursor(session)
        @test send_action(client, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
        batch = send_action(client, (; kind="collect", probe=0, after, measurements=2, frames=3); serial=4)
        @test batch.result.kind == "responses" && batch.result.valid === false
        @test length(batch.result.exposures) == 3 && batch.result.values == Float32[3, 4]
        @test all(exposure -> exposure.domain == 1 && exposure.generation == 7 && exposure.duration_ns == 50, batch.result.exposures)
        @test !owner.faulted && !session.failed && owner.held
        @test send_action(client, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=5).result.kind == "restored"
        @test send_action(client, (; kind="release"); serial=6).result.kind == "released"
        @test fetch(server) === owner && owner.restored && !owner.faulted
        close(client)
    end
end

@testset "pause fences new acquisitions while reference restoration remains allowed" begin
    mktempdir() do directory
        (; session, owner) = server_fixture()
        path = joinpath(directory, "paused.sock")
        listener = listen(path)
        enabled = Ref(true)
        server = @async Server.serve!(owner, listener; admission_enabled=() -> enabled[])
        client = connect(path)
        @test send_action(client, (; kind="hold"); serial=1).result.kind == "held"
        enabled[] = false
        @test send_action(client, (; kind="adopt", probe=0, figure=Float32[1, 2]); serial=2).result.reason == "cancelled"
        @test isempty(session.adopted) && owner.held && session.held
        @test send_action(client, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=3).result.kind == "restored"
        @test send_action(client, (; kind="release"); serial=4).result.kind == "released"
        @test fetch(server) === owner
        close(client)
    end
end

@testset "initial admission precedes the finite client acceptance budget" begin
    for outcome in (:complete, :timeout, :quit)
        mktempdir() do directory
            path = joinpath(directory, "admission.sock")
            (; session, owner) = server_fixture()
            enabled = Ref(false)
            quit = Ref(false)
            services = Ref(0)
            server = @async Server.serve!(owner, path;
                accept_timeout_ns=UInt64(100_000_000),
                admission_enabled=() -> enabled[], should_stop=() -> quit[],
                service_control=() -> (services[] += 1))
            @test timedwait(() -> ispath(path), 1.0; pollint=0.005) == :ok
            sleep(0.3) # Exceed the accept budget while graph owners prepare.
            @test !istaskdone(server) && ispath(path)
            @test services[] > 0 && !owner.held && !session.failed
            if istaskdone(server)
                try
                    fetch(server)
                catch
                end
                return
            end
            if outcome == :quit
                quit[] = true
            else
                enabled[] = true
                if outcome == :complete
                    client = connect(path)
                    try
                        @test send_action(client, (; kind="hold"); serial=1).result.kind == "held"
                        @test send_action(client, (; kind="restore", figure=Float32[0, 0],
                            rule=(; kind="immediate")); serial=2).result.kind == "restored"
                        @test send_action(client, (; kind="release"); serial=3).result.kind == "released"
                        @test fetch(server) === owner && owner.restored && !owner.faulted
                    finally
                        close(client)
                    end
                    return
                end
            end
            @test timedwait(() -> istaskdone(server), 2.0; pollint=0.005) == :ok
            @test_throws TaskFailedException fetch(server)
            @test owner.faulted && owner.held && session.failed && !ispath(path)
        end
    end
end

@testset "disconnect, incomplete record, accept timeout and quit retain hold/fault" begin
    for problem in (:disconnect, :partial, :oversized, :accept, :quit, :busy_disconnect)
        mktempdir() do directory
            path = joinpath(directory, "calibration.sock")
            (; session, owner) = server_fixture(; delay=0.05)
            quit = Ref(false)
            client = nothing
            server = @async Server.serve!(owner, path; accept_timeout_ns=UInt64(100_000_000),
                io_timeout_ns=UInt64(100_000_000), should_stop=() -> quit[])
            if problem == :quit
                quit[] = true
            elseif problem != :accept
                @test timedwait(() -> ispath(path), 1.0; pollint=0.005) == :ok
                client = connect(path)
                if problem == :disconnect
                    close(client)
                elseif problem == :partial
                    write(client, "{")
                    flush(client)
                elseif problem == :oversized
                    write(client, repeat(" ", Server.MAX_REQUEST_BYTES))
                    flush(client)
                else
                    @test send_action(client, (; kind="hold"); serial=1).result.kind == "held"
                    @test send_action(client, (; kind="adopt", probe=0, figure=Float32[1, 2]); serial=2).result.kind == "adopted"
                    after = Server.session_cursor(session)
                    @test send_action(client, (; kind="settle", probe=0, after, rule=(; kind="immediate")); serial=3).result.kind == "settled"
                    write(client, JSON3.write((; version=1, run=1, serial=4, timeout_ns=1_000_000_000,
                        action=(; kind="collect", probe=0, after, measurements=2, frames=4))), '\n')
                    flush(client)
                    close(client)
                end
            end
            @test timedwait(() -> istaskdone(server), 2.0; pollint=0.005) == :ok
            @test_throws TaskFailedException fetch(server)
            @test owner.faulted && owner.held && session.failed && session.held
            @test !owner.restored && !ispath(path)
            client === nothing || close(client)
        end
    end
end

# Use a real accepted Unix socket and delay return from its completed write
# until the peer has read the entire terminal ACK and closed. This establishes
# the immediate-close ordering without depending on task scheduler timing.
struct ImmediateCloseServerSocket
    endpoint::Base.PipeEndpoint
    peer_closed::Base.RefValue{Bool}
end
Base.read(socket::ImmediateCloseServerSocket, ::Type{UInt8}) = read(socket.endpoint, UInt8)
Base.close(socket::ImmediateCloseServerSocket) = close(socket.endpoint)
Base.flush(socket::ImmediateCloseServerSocket) = flush(socket.endpoint)
function Base.write(socket::ImmediateCloseServerSocket, payload::String)
    written = write(socket.endpoint, payload)
    if JSON3.read(payload).result.kind == "released"
        timedwait(() -> socket.peer_closed[], 1.0; pollint=0.001) == :ok || error("peer did not close after terminal ACK")
        eof(socket.endpoint) || error("peer EOF not observed")
    end
    return written
end

@testset "complete terminal ACK followed by immediate peer close preserves release" begin
    mktempdir() do directory
        (; session, owner) = server_fixture()
        listener = listen(joinpath(directory, "terminal.sock"))
        peer_closed = Ref(false)
        server = @async begin
            accepted = accept(listener)
            @test accepted.sendbuf === nothing
            try
                Server.serve_connection!(owner, ImmediateCloseServerSocket(accepted, peer_closed))
            finally
                close(listener)
            end
        end
        client = connect(joinpath(directory, "terminal.sock"))
        try
            @test send_action(client, (; kind="hold"); serial=1).result.kind == "held"
            @test send_action(client, (; kind="restore", figure=Float32[0, 0], rule=(; kind="immediate")); serial=2).result.kind == "restored"
            terminal = send_action(client, (; kind="release"); serial=3)
            @test terminal.version == 1 && terminal.run == 1 && terminal.serial == 3
            @test terminal.result.kind == "released"
            close(client)
            peer_closed[] = true
            @test fetch(server) === owner
            @test owner.phase == :released && owner.restored && !owner.held && !owner.faulted
            @test !session.failed && !session.held
        finally
            close(client)
            peer_closed[] = true
            close(listener)
        end
    end
end

# Capture fixtures supply typed packed owned arrays, never native pointers.
mutable struct CaptureTestSession
    inner::ServerTestSession
    raw::Vector{UInt16}
    flux::Vector{Float32}
    validity::Vector{Bool}
    writes::Int
    partial_write::Bool
    write_delay::Float64
end
Server.session_cursor(session::CaptureTestSession) = Server.session_cursor(session.inner)
Server.session_domain(session::CaptureTestSession) = session.inner.domain
Server.session_domain_bytes(session::CaptureTestSession) = collect(session.inner.domain)
Server.session_hold!(session::CaptureTestSession) = Server.session_hold!(session.inner)
Server.session_release!(session::CaptureTestSession) = Server.session_release!(session.inner)
Server.session_fault!(session::CaptureTestSession) = Server.session_fault!(session.inner)
Server.session_adopt!(session::CaptureTestSession, figure; timeout_ns) = Server.session_adopt!(session.inner, figure; timeout_ns)
Server.session_response_values(session::CaptureTestSession) = session.inner.values
Server.session_capture_values(session::CaptureTestSession) = (; raw=session.raw,
    slopes=session.inner.values, flux=session.flux, validity=session.validity)
function Server.session_acquire!(session::CaptureTestSession; timeout_ns, require_valid)
    receipt = Server.session_acquire!(session.inner; timeout_ns, require_valid)
    fill!(session.raw, UInt16(session.inner.sequence))
    fill!(session.validity, receipt.valid)
    return receipt
end
function Server.capture_write_payload(session::CaptureTestSession, io, payload)
    session.writes += 1
    session.write_delay > 0 && sleep(session.write_delay)
    return session.partial_write ? write(io, view(payload, 1:7)) : write(io, payload)
end
function capture_fixture(root; maximum_bytes=2Server.CLASSIC_CAPTURE_BYTES, valid=true)
    inner = server_fixture(; samples=[zeros(Float32, 376)]).session
    inner.valid = valid
    session = CaptureTestSession(inner, zeros(UInt16, 352 * 352), fill(10.0f0, 188), fill(valid, 188), 0, false, 0.0)
    store = Server.CaptureStore(joinpath(root, "capture"); maximum_bytes,
        stage="dark-training", illumination=:dark,
        settings=(; detector_config=(; bits=12, photon_noise=true), graph_sha256="fixture-graph"))
    owner = Server.Owner(session; normal_controller_absent=true, command_count=2,
        measurement_count=376, maximum_timeout_ns=UInt64(20_000_000_000), capture=store)
    @test apply_server!(owner, (; kind="hold")).result.kind == "held"
    @test apply_server!(owner, (; kind="adopt", probe=0, figure=Float32[0, 0]); serial=2).result.kind == "adopted"
    @test apply_server!(owner, (; kind="settle", probe=0, after=Server.session_cursor(session),
        rule=(; kind="immediate")); serial=3).result.kind == "settled"
    return (; owner, session, store)
end
capture_action(session; frames=1, probe=0, after=Server.session_cursor(session)) =
    (; kind="capture", probe, after, frames)

@testset "bounded complete dark capture retains false WFS quality" begin
    mktempdir() do root
        (; owner, session, store) = capture_fixture(root; valid=false)
        reply = apply_server!(owner, capture_action(session; frames=2); serial=4,
            timeout_ns=UInt64(20_000_000_000))
        @test reply.result.kind == "captured"
        @test reply.result.frames == 2 && reply.result.bytes == 2Server.CLASSIC_CAPTURE_BYTES
        @test ncodeunits(Server.encode_reply(reply)) <= Server.MAX_REPLY_BYTES
        @test reply.result.manifest == "4/manifest.json"
        manifest_path = joinpath(store.directory, reply.result.manifest)
        bytes = read(manifest_path)
        @test reply.result.sha256 == bytes2hex(Server.sha256(bytes))
        @test reply.result.metadata_bytes == length(bytes)
        manifest = JSON3.read(bytes)
        @test manifest.run == 1 && manifest.serial == 4 && manifest.probe == 0
        @test manifest.stage == "dark-training" && manifest.illumination == "dark"
        @test manifest.settings.detector_config.bits == 12
        @test manifest.settings_sha256 == store.settings_sha256
        @test UInt8.(manifest.acquisition_domain_mapping.complete_domain) == collect(session.inner.domain)
        @test manifest.acquisition_domain_mapping.opaque_domain == 1
        @test [r.sequence for r in manifest.exposures] == [1, 2]
        @test [r.start_model_ns for r in manifest.exposures] == [0, 50]
        @test all(r -> r.generation == 7 && r.duration_ns == 50 && !r.valid, manifest.exposures)
        for record in manifest.exposures
            @test record.domain == 1
            for (name, count, element_type) in ((:raw, 247808, "U16_LE"), (:slopes, 1504, "F32_LE"),
                (:flux, 752, "F32_LE"), (:validity, 188, "BOOL8"))
                file = getproperty(record.files, name)
                path = joinpath(dirname(manifest_path), record.directory, file.path)
                @test file.bytes == count && filesize(path) == count
                @test file.sha256 == bytes2hex(Server.sha256(read(path)))
                @test file.element_type == element_type && file.layout == "ROW_MAJOR"
            end
            @test all(==(UInt16(record.sequence)), reinterpret(UInt16,
                read(joinpath(dirname(manifest_path), record.directory, record.files.raw.path))))
        end
        @test !owner.faulted && owner.held && owner.phase == :collected
        @test !session.inner.failed && store.reserved_bytes == 2Server.CLASSIC_CAPTURE_BYTES
        @test length(session.inner.exposure_budgets) == 2
        @test session.inner.exposure_budgets[2] < session.inner.exposure_budgets[1]
        @test apply_server!(owner, (; kind="collect", probe=0, after=Server.session_cursor(session),
            measurements=376, frames=1); serial=5).result.reason == "invalid_evidence"
        @test session.inner.sequence == 2
        @test apply_server!(owner, (; kind="restore", figure=Float32[0, 0],
            rule=(; kind="immediate")); serial=6).result.kind == "restored"
        @test apply_server!(owner, (; kind="release"); serial=7).result.kind == "released"
        @test !owner.faulted && !owner.held && !session.inner.failed
        @test read(manifest_path) == bytes # completed captures survive restoration/release
    end
end

@testset "capture capacity and association reject before acquisition" begin
    mktempdir() do root
        (; owner, session, store) = capture_fixture(root; maximum_bytes=Server.CLASSIC_CAPTURE_BYTES)
        @test apply_server!(owner, capture_action(session; frames=2); serial=4).result.reason == "invalid_evidence"
        @test session.inner.sequence == 0 && isempty(session.inner.exposure_budgets)
        @test store.reserved_bytes == 0 && isempty(readdir(store.directory))
        @test !owner.faulted && owner.phase == :settled
        @test apply_server!(owner, capture_action(session; probe=1); serial=5).result.reason == "invalid_evidence"
        stale = merge(Server.session_cursor(session), (; sequence=UInt64(1)))
        @test apply_server!(owner, capture_action(session; after=stale); serial=6).result.reason == "invalid_evidence"
        @test session.inner.sequence == 0
        complete = apply_server!(owner, capture_action(session); serial=7, timeout_ns=UInt64(20_000_000_000))
        @test complete.result.kind == "captured"
        @test apply_server!(owner, capture_action(session); serial=8).result.reason == "invalid_evidence"
        @test apply_server!(owner, (; kind="adopt", probe=1, figure=Float32[0, 0]); serial=9).result.kind == "adopted"
        @test apply_server!(owner, (; kind="settle", probe=1, after=Server.session_cursor(session),
            rule=(; kind="immediate")); serial=10).result.kind == "settled"
        @test apply_server!(owner, capture_action(session; probe=1); serial=11).result.reason == "invalid_evidence"
        @test session.inner.sequence == 1 && store.reserved_bytes == Server.CLASSIC_CAPTURE_BYTES
        @test readdir(store.directory) == ["7"] && !owner.faulted
    end
    fixture = held_adopted_fixture()
    @test apply_server!(fixture.owner, (; kind="settle", probe=0, after=Server.session_cursor(fixture.session),
        rule=(; kind="immediate")); serial=3).result.kind == "settled"
    @test apply_server!(fixture.owner, capture_action(fixture.session); serial=4).result.reason == "invalid_evidence"
    @test fixture.session.sequence == 0 && !fixture.owner.faulted
end

@testset "capture failure keeps partial evidence and faults held owner" begin
    for scenario in (:partial_write, :deadline, :disconnect, :publication)
        mktempdir() do root
            (; owner, session, store) = capture_fixture(root)
            if scenario == :partial_write
                session.partial_write = true
            elseif scenario == :deadline
                session.write_delay = 0.03
            end
            check_connection = () -> begin
                if scenario == :disconnect && session.writes > 0
                    throw(Server.EndpointFailure())
                elseif scenario == :publication && isfile(joinpath(store.directory, "4", "manifest.json"))
                    throw(Server.EndpointFailure())
                end
                nothing
            end
            timeout = scenario == :deadline ? UInt64(10_000_000) : UInt64(20_000_000_000)
            reply = Server.execute!(owner, server_request(capture_action(session); serial=4,
                timeout_ns=timeout); check_connection)
            @test reply.result.kind == "failed" && reply.result.reason == "endpoint"
            @test owner.faulted && owner.held && owner.phase == :fault && owner.probe === nothing
            @test session.inner.failed && session.inner.held && session.inner.sequence == 1
            @test !isfile(joinpath(store.directory, "4", "manifest.json"))
            @test isdir(joinpath(store.directory, "4", "1"))
            @test store.pending_manifest === nothing
            @test apply_server!(owner, (; kind="restore", figure=Float32[0, 0],
                rule=(; kind="immediate")); serial=5).result.reason == "endpoint"
            @test session.inner.sequence == 1
        end
    end
end

@testset "capture strict schema and startup storage validation" begin
    @test Server.require_capture_endian(UInt32(0x04030201)) === nothing
    @test_throws ArgumentError Server.require_capture_endian(UInt32(0x01020304))
    cursor = (; domain=1, generation=7, sequence=0, model_ns=0)
    for action in ((; kind="capture", probe=0, after=cursor, frames=0),
        (; kind="capture", probe=0, after=cursor, frames=4097),
        (; kind="capture", probe=true, after=cursor, frames=1),
        (; kind="capture", probe=0, after=cursor, frames=1.0),
        (; kind="capture", probe=0, after=cursor, frames=1, directory="client-path"))
        @test_throws Server.InvalidRequest server_request(action)
    end
    mktempdir() do root
        path = joinpath(root, "new")
        @test_throws ArgumentError Server.CaptureStore(path; maximum_bytes=UInt64(1), profile=:copper)
        @test_throws ArgumentError Server.CaptureStore(path; maximum_bytes=UInt64(0))
        @test_throws ArgumentError Server.CaptureStore(path; maximum_bytes=UInt64(1), stage="../escape")
        @test_throws ArgumentError Server.CaptureStore(path; maximum_bytes=UInt64(1), settings=(; oversized=repeat("x", 16385)))
        @test !ispath(path)
        store = Server.CaptureStore(path; maximum_bytes=UInt64(1))
        @test stat(path).mode & 0o777 == 0o700
        @test_throws ArgumentError Server.CaptureStore(path; maximum_bytes=UInt64(1))
        link = joinpath(root, "link")
        symlink(joinpath(root, "missing"), link)
        @test_throws ArgumentError Server.CaptureStore(link; maximum_bytes=UInt64(1))
    end
end

@testset "capture packed view dispatch and malformed payload rejection" begin
    mktempdir() do root
        (; owner, session, store) = capture_fixture(root)
        directory = joinpath(store.directory, "views")
        mkdir(directory)
        raw = view(ones(UInt16, 352 * 352 + 2), 2:(352 * 352 + 1))
        slopes = view(zeros(Float32, 378), 2:377)
        flux = view(fill(10.0f0, 190), 2:189)
        validity = view(fill(false, 190), 2:189)
        values = (; raw, slopes, flux, validity)
        files = Server.capture_frame_payload!(owner, directory, values,
            time_ns() + UInt64(20_000_000_000), () -> nothing)
        @test sum(file.bytes for file in files) == Server.CLASSIC_CAPTURE_BYTES
        @test read(joinpath(directory, "raw.u16le")) == reinterpret(UInt8, raw)
        @test session.inner.sequence == 0 # payload dispatch fixture, no endpoint qualification
        before = session.writes
        for malformed in (merge(values, (; raw=zeros(Float32, 352 * 352))),
            merge(values, (; raw=view(zeros(UInt16, 2 * 352 * 352), 1:2:(2 * 352 * 352)))),
            merge(values, (; raw=zeros(UInt16, 7))))
            @test_throws Server.EndpointFailure Server.capture_frame_payload!(owner, directory,
                malformed, time_ns() + UInt64(20_000_000_000), () -> nothing)
        end
        @test session.writes == before
    end
end

@testset "bounded capture wire descriptor and paused admission" begin
    mktempdir() do root
        (; owner, session, store) = capture_fixture(root; valid=false)
        listener = listen(joinpath(root, "capture.sock"))
        enabled = Ref(false)
        # The admission timer starts only on resume; no science occurs while paused.
        server = @async Server.serve!(owner, listener; admission_enabled=() -> enabled[])
        client = connect(joinpath(root, "capture.sock"))
        enabled[] = true
        reply = send_action(client, capture_action(session; frames=2); serial=4,
            timeout_ns=UInt64(20_000_000_000))
        @test reply.result.kind == "captured" && reply.result.bytes == 2Server.CLASSIC_CAPTURE_BYTES
        @test reply.result.cursor.sequence == 2
        @test reply.result.manifest == "4/manifest.json"
        @test !haskey(reply.result, :values) && !haskey(reply.result, :exposures)
        @test reply.result.sha256 == bytes2hex(Server.sha256(read(joinpath(store.directory, reply.result.manifest))))
        enabled[] = false
        @test send_action(client, capture_action(session); serial=5).result.reason == "cancelled"
        @test session.inner.sequence == 2 && owner.phase == :collected
        @test send_action(client, (; kind="restore", figure=Float32[0, 0],
            rule=(; kind="immediate")); serial=6).result.kind == "restored"
        @test send_action(client, (; kind="release"); serial=7).result.kind == "released"
        @test fetch(server) === owner && !owner.faulted && owner.restored
        close(client)
    end
end
