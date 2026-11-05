# Optional native host selector: use the source cohort and --threads=2,1.
module MediaSessionHostTests
using Test, PipeWireAORTC, PipeWireAO
const S = PipeWireAORTC.MediaSession
const C = PipeWireAORTC.ControlCodec
const R = PipeWireAORTC.RunnerCodec
const Clocks = S.Clocks
const SECOND = Int64(1_000_000_000)
include("control_private_core.jl")

function host_session(socket, directory, daemon; journaled = false)
    policy = Dict{String,Any}(
        "instance"=>"101",
        "controller.instance"=>"102",
        "admission.controller-instance"=>"103",
        "node.name"=>"host-session",
        "controller.node.name"=>"pipewireao.rtc.controller.host-session",
        "startup.timeout-ms"=>300000,
        "session.uuid"=>"23af16ce-86f6-4d06-b8fc-eb03c6c63776",
        "properties"=>Dict{String,String}(),
        "core.owner"=>Dict("pid"=>getpid(daemon), "nodes"=>String[]),
        "owners"=>[],
        "node.pids"=>Dict{String,Int}(),
        "source"=>Dict(
            "role"=>"missing-source",
            "control-node"=>"missing-source",
            "pid"=>getpid(),
        ),
        "session"=>Dict(
            "sources"=>[],
            "graphs"=>[],
            "sinks"=>[],
            "links"=>[
                Dict("output"=>"missing-source:output", "input"=>"missing-sink:input"),
            ],
        ),
    )
    journaled && (policy["journal.path"] = joinpath(directory, "host.sqlite"))
    config = Dict(
        "context.properties"=>Dict(
            "remote.name"=>socket,
            "library.use-fallback"=>false,
            "support.dbus"=>false,
        ),
        "context.modules"=>[
            Dict("name"=>"libpipewire-module-protocol-native"),
            Dict("name"=>"libpipewire-module-client-node"),
        ],
        "pipewireao.session"=>policy,
    )
    path = joinpath(directory, "host.conf")
    PipeWireAORTC.ScienceExport.write_spa_config(path, config)
    return S.Session(path; clock = Clocks.CachedNanoClock(Int64(0)))
end

function wait_host(predicate, session)
    clock = Clocks.SystemNanoClock()
    deadline = Base.Checked.checked_add(Clocks.time_nanos(clock), 60*SECOND)
    while true
        S.Agent.do_work(session)
        predicate() && return nothing
        Clocks.time_nanos(clock) < deadline || error("native host observation timed out")
        sleep(0.001)
    end
end

function stop_effect_task!(session)
    session.active_job === nothing || (session.active_job.cancelled = true)
    session.active_task === nothing || wait(session.active_task)
    session.active_job = nothing
    session.active_task = nothing
    session.effect_result = nothing
    return nothing
end

function prepare_host!(session)
    wait_host(session) do
        session.controller !== nothing && haskey(session.objects, node_id(session.endpoint))
    end
    stop_effect_task!(session)
    # These receipts prepare only the policy test. No scientific owner exists.
    for _ = 1:16
        ticket = session.machine.effect
        ticket === nothing && break
        S.complete!(session.machine, ticket)
    end
    id = something(session.controller)
    launcher = S.Identity(id.global_id, id.serial, UInt64(id.instance), UInt32(getpid()))
    S.submit!(session.machine, S.Request(S.InspectWarmup(); controller = launcher))
    S.take_replies!(session.machine)
    S.submit!(session.machine, S.Request(S.Admit(); controller = launcher))
    S.take_replies!(session.machine)
    @test session.machine.lifecycle == R.Ready
    S.drain!(session)
    return nothing
end

function send_pending!(session, command)
    header = C.RequestHeader(
        something(session.controller),
        Int64(101),
        Int64(1),
        R.operation_id(command),
        60*SECOND,
    )
    request = R.encode_request(header, command)
    endpoint = session.objects[node_id(session.endpoint)]
    set_param!(endpoint.proxy, PipeWireAO.SPA.PARAM_PROPS, request)
    wait_host(()->length(session.requests) == 1, session)
    @test session.ingress.pending !== nothing
    @test session.ingress.pending.dispatched
    return only(values(session.requests))
end

function disconnect_pending!(session)
    stop_effect_task!(session)
    S.fail!(
        session.machine,
        something(session.machine.effect),
        "injected operation failure";
        submitted = true,
    )
    S.drain!(session)
    S.fail!(
        session.machine,
        something(session.machine.effect),
        "injected source Hold failure";
        submitted = true,
    )
    S.drain!(session)
    ticket = something(session.machine.effect)
    @test ticket.effect === S.Disconnect()
    S.perform!(session, S.Job(ticket, false), ticket.effect)
    @test !isopen(session.endpoint) && !isopen(session.core) && !session.done
    S.update!(session, S.EffectCompleted(ticket, nothing, Clocks.time_nanos(session.clock)))
    @test session.done && session.exitcode == 1
    return nothing
end

function drain_failure(session)
    try
        S.drain!(session)
        return nothing
    catch error
        return error
    end
end

@testset "Native host terminal paths" begin
    for journaled in (false, true)
        @testset "Disconnect with mapped ingress, journaled=$journaled" begin
            with_control_private_core() do socket, directory, daemon
                session = host_session(socket, directory, daemon; journaled)
                try
                    prepare_host!(session)
                    command =
                        journaled ?
                        R.RunnerCommand(
                            :properties_set,
                            "graph",
                            Dict("controller:gain"=>R.RunnerScalar(:int, Int32(1))),
                        ) : R.RunnerCommand(:quit)
                    ticket = send_pending!(session, command)
                    disconnect_pending!(session)
                    @test drain_failure(session) === nothing
                    @test isempty(session.requests)
                    if journaled
                        writer = something(session.journal)
                        close(writer) # Accepted terminal work must drain despite no wire.
                        result = something(S.take_result!(writer))
                        @test result.success
                        S.Ingress.journal_receipt!(
                            session.ingress,
                            result.token,
                            result.success,
                            result.message,
                        )
                        @test drain_failure(session) === nothing
                        database = S.SQLite.DB(writer.path)
                        try
                            rows = S.DBInterface.execute(
                                database,
                                "SELECT event,record,operation_key FROM operation_events ORDER BY sequence",
                            ) do records
                                [
                                    (
                                        event = String(row.event),
                                        record = Vector{UInt8}(row.record),
                                        key = String(row.operation_key),
                                    ) for row in records
                                ]
                            end
                            @test [row.event for row in rows] == ["requested", "unknown"]
                            @test rows[1].key == rows[2].key
                            @test rows[2].record == session.ingress.completion.data
                        finally
                            close(database)
                        end
                    end
                    completion = R.decode_completion(session.ingress.completion)
                    @test completion.header.token == ticket.header.token
                    @test completion.header.result == -5
                    @test occursin("outcome unknown", something(completion.error).message)
                    @test session.ingress.pending === nothing
                    @test session.done && session.exitcode == 1
                finally
                    close(session)
                end
            end
        end
    end

    for disposition in (:fail, :expire)
        @testset "Accepted Quit publication fence $disposition" begin
            with_control_private_core() do socket, directory, daemon
                session = host_session(socket, directory, daemon)
                try
                    prepare_host!(session)
                    S.submit!(session.machine, S.Request(S.Quit()))
                    S.drain!(session)
                    for _ = 1:6
                        S.complete!(session.machine, something(session.machine.effect))
                    end
                    ticket = something(session.machine.effect)
                    @test ticket.effect === S.PublishQuit()
                    @test !session.done
                    if disposition === :fail
                        S.update!(
                            session,
                            S.EffectFailed(ticket, "publication failed", false),
                        )
                    else
                        Clocks.update!(session.source_clock, ticket.deadline)
                        Clocks.update!(session.clock, ticket.deadline)
                        S.tick!(session.machine)
                    end
                    S.drain!(session)
                    @test session.done && session.exitcode == 0
                    @test session.machine.lifecycle == R.Offline
                    @test session.machine.effect === nothing
                    @test session.machine.cleanup_failure !== nothing
                    S.update!(session, S.EffectCompleted(ticket, nothing, ticket.deadline))
                    S.update!(session, S.EffectFailed(ticket, "late failure", false))
                    @test session.done && session.exitcode == 0
                    @test isempty(S.take_replies!(session.machine))
                finally
                    close(session)
                end
            end
        end
    end
end
end
