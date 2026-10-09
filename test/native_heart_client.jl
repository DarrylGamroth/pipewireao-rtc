using Test, JSON3, SHA, PipeWireAO, PipeWireAODeployment

include("native_control_private_core.jl")

const Heart = PipeWireAODeployment.NativeHeartCodec
const HeartClient = PipeWireAODeployment.NativeHeartClient
const ControlClient = PipeWireAODeployment.NativeControlClient
const ControlEndpoint = PipeWireAODeployment.NativeControlEndpoint
const Envelope = PipeWireAODeployment.NativeControlCodec
const WrongProfile = PipeWireAODeployment.NativeSessionProfile.Profile()
const SPA = PipeWireAO.SPA
const OWNER_NAME = "test.native.heart.owner"
const LIFECYCLE_OWNER_NAME = "test.native.heart.lifecycle.owner"

mutable struct HeartFixtureState
    root::String
    child::Union{Nothing,Base.Process}
    generation::Int64
    effects::Int
    fail_next::Bool
end

function heart_sleep_child()
    return run(pipeline(`sleep 600`; stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
end

function heart_snapshot(state::HeartFixtureState)
    child = state.child
    child !== nothing && process_running(child) || error("fixture HEART child is not running")
    data = Dict("generation"=>state.generation, "child_pid"=>getpid(child),
        "owner_pid"=>getpid(), "fixture"=>"sleep-subprocess-only")
    path = joinpath(state.root, "heart-generation-$(state.generation).json")
    if !isfile(path)
        open(path, "w") do io
            write(io, JSON3.write(data), "\n")
        end
    else
        current = JSON3.read(read(path, String), Dict{String,Any})
        current["generation"] == state.generation && current["child_pid"] == getpid(child) ||
            error("fixture generation report would change after sealing")
    end
    bytes = read(path)
    return Heart.HeartSnapshot(state.generation, UInt32(getpid(child)), nothing, true,
        Heart.Streaming, true, true, path, bytes2hex(sha256(bytes)))
end

function replace_heart_child!(state::HeartFixtureState)
    old = something(state.child)
    kill(old, Base.SIGTERM)
    wait_proof(() -> process_exited(old), 5, "fixture sleep child exit")
    wait(old)
    state.generation += 1
    state.child = heart_sleep_child()
    process_running(state.child) || error("replacement fixture sleep child failed to start")
    return heart_snapshot(state)
end

# Keep fixture behavior selected by command type, as the owner's operation API
# does, rather than branching on dynamically inspected command values.
function lifecycle_effect!(::Heart.HeartCommand{:status}, state::HeartFixtureState,
        endpoint, ticket)
    return Heart.Ready, heart_snapshot(state)
end

function lifecycle_effect!(::Heart.HeartCommand{:connect}, state::HeartFixtureState,
        endpoint, ticket)
    snapshot = heart_snapshot(state)
    return Heart.Ready, snapshot
end

function lifecycle_effect!(::Heart.HeartCommand{:shutdown}, state::HeartFixtureState,
        endpoint, ticket)
    child = something(state.child)
    child_pid = UInt32(getpid(child))
    stop_proof_child!(child, "fixture HEART sleep child")
    snapshot = Heart.HeartSnapshot(state.generation, child_pid, Int32(child.exitcode),
        false, Heart.Streaming, true, true, "", "")
    ControlEndpoint.state!(endpoint, Heart.Stopped)
    return Heart.Stopped, snapshot
end

function run_native_heart_lifecycle_proof(socket, daemon)
    chmod(dirname(socket), 0o700)
    instance = Int64(time_ns() % UInt64(typemax(Int64) - 2)) + 1
    root = mktempdir(prefix="native-heart-lifecycle-")
    state = HeartFixtureState(root, nothing, 1, 0, false)
    loop = ThreadLoop("test.native-heart-lifecycle-owner")
    context = core = endpoint = nothing
    client = nothing
    dispatcher = nothing
    quit = Ref(false)
    preparing_seen = Ref(false)
    preparing_since = Ref{Union{Nothing,Float64}}(nothing)
    dispatcher_failure = Ref{Any}(nothing)
    check_owner() = begin
        dispatcher_failure[] === nothing || throw(dispatcher_failure[])
        Base.process_exited(daemon) && error("private core exited during HEART lifecycle fixture")
        nothing
    end
    try
        state.child = heart_sleep_child()
        initial = heart_snapshot(state)
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name"=>socket))
        end
        endpoint = ControlEndpoint.Endpoint(Heart.HEART_PROFILE,
            Union{Heart.HeartCommand{:status},Heart.HeartCommand{:reset},
                Heart.HeartCommand{:connect},Heart.HeartCommand{:shutdown}},
            loop, core, LIFECYCLE_OWNER_NAME, instance, Heart.Preparing)
        start!(loop)
        dispatcher = @async try
            while !quit[]
                ControlEndpoint.poll!(endpoint)
                if endpoint.lifecycle === Heart.Preparing &&
                        any(controller -> controller.verified && !controller.retired, endpoint.controllers)
                    preparing_seen[] = true
                    preparing_since[] === nothing && (preparing_since[] = time())
                    if time() - something(preparing_since[]) >= 0.1
                        ControlEndpoint.state!(endpoint, Heart.Ready)
                    end
                end
                ticket = ControlEndpoint.take!(endpoint)
                if ticket !== nothing
                    ControlEndpoint.check_ticket(endpoint, ticket)
                    state.effects += 1
                    lifecycle, snapshot = lifecycle_effect!(ticket.command, state, endpoint, ticket)
                    header = Envelope.ReplyHeader(ticket.header.controller, endpoint.instance,
                        ticket.header.token, ticket.header.operation, Int32(0))
                    reply = ControlClient.encode_completion(Heart.HEART_PROFILE, header,
                        lifecycle, snapshot, "")
                    ControlEndpoint.complete!(endpoint, ticket, reply)
                end
                sleep(0.002)
            end
        catch error
            dispatcher_failure[] = error
            rethrow()
        end
        deadline() = ControlClient.monotonic() + 10
        client = HeartClient.connect(socket, LIFECYCLE_OWNER_NAME, getpid(), instance;
            deadline=deadline(), check=check_owner)
        @test initial.generation == 1
        @test preparing_seen[]
        @test client.observation.capability.lifecycle === Heart.Ready
        @test state.effects == 1 # the admission wrapper's fresh status

        connected = HeartClient.connect!(client; deadline=deadline(), check=check_owner)
        @test connected.generation == initial.generation
        @test connected.child_pid == initial.child_pid
        @test connected.alive
        @test endpoint.lifecycle === Heart.Ready
        @test state.effects == 2

        child = something(state.child)
        stopped = HeartClient.shutdown!(client; deadline=deadline(), check=check_owner)
        @test stopped.generation == connected.generation
        @test stopped.child_pid == connected.child_pid
        @test !stopped.alive
        @test stopped.child_returncode !== nothing
        @test process_exited(child)
        @test endpoint.lifecycle === Heart.Stopped
        @test state.effects == 3
    finally
        quit[] = true
        if dispatcher !== nothing && !istaskdone(dispatcher)
            try wait(dispatcher) catch end
        end
        client === nothing || try close(client) catch end
        endpoint === nothing || try close(endpoint) catch end
        if loop !== nothing
            with_thread_loop_lock(loop) do _
                for resource in (core, context)
                    resource === nothing || try close(resource) catch end
                end
            end
            try close(loop) catch end
        end
        child = state.child
        child !== nothing && !process_exited(child) &&
            try stop_proof_child!(child, "fixture HEART sleep child") catch end
        rm(root; recursive=true, force=true)
    end
end

function run_native_heart_client_proof(socket, directory, daemon, evidence)
    chmod(dirname(socket), 0o700)
    owner_instance = Int64(time_ns() % UInt64(typemax(Int64) - 2)) + 1
    report_root = joinpath(directory, "heart-reports")
    mkpath(report_root)
    state = HeartFixtureState(report_root, nothing, 1, 0, false)
    loop = ThreadLoop("test.native-heart-owner")
    context = core = endpoint = nothing
    clients = ControlClient.Client[]
    dispatcher = nothing
    quit = Ref(false)
    run_effects = Ref(true)
    dispatcher_failure = Ref{Any}(nothing)
    latest_snapshot = Ref{Union{Nothing,Heart.HeartSnapshot}}(nothing)
    function owner_check()
        dispatcher_failure[] === nothing || throw(dispatcher_failure[])
        Base.process_exited(daemon) && error("private core exited before the transport-loss case")
        return nothing
    end
    try
        state.child = heart_sleep_child()
        initial = heart_snapshot(state)
        latest_snapshot[] = initial
        with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name"=>socket))
        end
        endpoint = ControlEndpoint.Endpoint(Heart.HEART_PROFILE,
            Union{Heart.HeartCommand{:status},Heart.HeartCommand{:reset}},
            loop, core, OWNER_NAME, owner_instance, Heart.Ready)
        start!(loop)
        dispatcher = @async try
            while !quit[]
                ControlEndpoint.poll!(endpoint)
                if run_effects[]
                    ticket = ControlEndpoint.take!(endpoint)
                    if ticket !== nothing
                        ControlEndpoint.check_ticket(endpoint, ticket)
                        state.effects += 1
                        if state.fail_next
                            state.fail_next = false
                            header = Envelope.ReplyHeader(ticket.header.controller,
                                endpoint.instance, ticket.header.token, ticket.header.operation,
                                Int32(-5))
                            failed = ControlClient.encode_completion(Heart.HEART_PROFILE,
                                header, Heart.Ready, nothing, "fixture effect failed")
                            ControlEndpoint.complete!(endpoint, ticket, failed)
                        else
                            if ticket.command isa Heart.HeartCommand{:reset}
                                ControlEndpoint.state!(endpoint, Heart.Preparing)
                                latest_snapshot[] = replace_heart_child!(state)
                                ControlEndpoint.state!(endpoint, Heart.Ready)
                            else
                                latest_snapshot[] = heart_snapshot(state)
                            end
                            header = Envelope.ReplyHeader(ticket.header.controller,
                                endpoint.instance, ticket.header.token, ticket.header.operation,
                                Int32(0))
                            reply = ControlClient.encode_completion(Heart.HEART_PROFILE,
                                header, Heart.Ready, latest_snapshot[], "")
                            ControlEndpoint.complete!(endpoint, ticket, reply)
                        end
                    end
                end
                sleep(0.002)
            end
        catch error
            dispatcher_failure[] = error
            rethrow()
        end
        check_owner() = begin
            owner_check()
            istaskfailed(dispatcher) && fetch(dispatcher)
            nothing
        end
        deadline() = ControlClient.monotonic() + 10
        connect(; profile=Heart.HEART_PROFILE, pid=getpid(), instance=owner_instance) =
            ControlClient.connect(profile, socket, OWNER_NAME, pid, instance;
                deadline=deadline(), check=check_owner)

        @test_throws ControlClient.UnknownOutcome connect(pid=getpid()+1)
        @test_throws ControlClient.UnknownOutcome connect(instance=owner_instance+1)
        @test_throws ControlClient.UnknownOutcome connect(profile=WrongProfile)

        client = HeartClient.connect(socket, OWNER_NAME, getpid(), owner_instance;
            deadline=deadline(), check=check_owner)
        push!(clients, client)
        @test client.observation.owner_pid == getpid()
        @test client.observation.instance == owner_instance
        @test client.identity !== nothing
        @test client.identity in client.observation.capability.controllers

        first_snapshot, first_report = HeartClient.generation_report(client, report_root;
            deadline=deadline(), check=check_owner)
        @test first_snapshot.generation == initial.generation
        @test first_snapshot.child_pid == initial.child_pid
        @test first_snapshot.report_sha256 == initial.report_sha256
        @test first_report.generation == first_snapshot.generation
        @test first_report.child_pid == first_snapshot.child_pid
        @test first_report.owner_pid == getpid()
        @test first_snapshot.report_sha256 == bytes2hex(sha256(read(first_snapshot.report_path)))
        cp(first_snapshot.report_path, joinpath(evidence, basename(first_snapshot.report_path)))

        # A negative completion with no snapshot keeps the Ready owner and child facts intact.
        before_effects = state.effects
        state.fail_next = true
        negative = ControlClient.request!(client, Heart.HeartCommand(:status);
            deadline=deadline(), check=check_owner)
        @test negative isa Heart.HeartCompletion
        @test negative.header.result < 0
        @test negative.snapshot === nothing
        @test negative.lifecycle === Heart.Ready
        @test endpoint.lifecycle === Heart.Ready
        @test state.effects == before_effects + 1
        @test process_running(state.child)
        @test state.generation == first_snapshot.generation
        @test_throws ControlClient.UnknownOutcome HeartClient.require_ready(client, first_snapshot)

        # Native reset must replace the real owned subprocess and advance generation.
        old_child = something(state.child)
        next_snapshot = HeartClient.reset!(client, first_snapshot;
            deadline=ControlClient.monotonic() + 12, check=check_owner)
        @test next_snapshot.generation == first_snapshot.generation + 1
        @test next_snapshot.child_pid != first_snapshot.child_pid
        @test process_exited(old_child)
        @test state.effects == before_effects + 2
        @test_throws ErrorException HeartClient.require_ready(client, first_snapshot)
        @test HeartClient.require_ready(client, next_snapshot) === nothing
        verified_snapshot, verified_report = HeartClient.generation_report(client, report_root;
            deadline=deadline(), check=check_owner)
        @test verified_snapshot.generation == next_snapshot.generation
        @test verified_snapshot.child_pid == next_snapshot.child_pid
        @test verified_snapshot.report_sha256 == next_snapshot.report_sha256
        @test verified_report.generation == next_snapshot.generation
        @test verified_report.child_pid == next_snapshot.child_pid
        @test next_snapshot.report_sha256 == bytes2hex(sha256(read(next_snapshot.report_path)))
        cp(next_snapshot.report_path, joinpath(evidence, basename(next_snapshot.report_path)))

        # A later failed completion must not erase the newer generation fence.
        state.fail_next = true
        post_reset_failure = ControlClient.request!(client, Heart.HeartCommand(:status);
            deadline=deadline(), check=check_owner)
        @test post_reset_failure.header.result < 0
        @test post_reset_failure.lifecycle === Heart.Ready
        @test post_reset_failure.snapshot === nothing
        @test endpoint.lifecycle === Heart.Ready
        @test process_running(state.child)
        @test state.generation == next_snapshot.generation
        @test_throws ControlClient.UnknownOutcome HeartClient.require_ready(client, first_snapshot)
        recovered_snapshot = HeartClient.status(client; deadline=deadline(), check=check_owner)
        @test recovered_snapshot.generation == next_snapshot.generation
        @test_throws ErrorException HeartClient.require_ready(client, first_snapshot)
        @test HeartClient.require_ready(client, recovered_snapshot) === nothing

        # Removal after admission has an unknown result and never starts the effect.
        removed_client = connect()
        push!(clients, removed_client)
        run_effects[] = false
        effects_before_removal = state.effects
        removed_task = @async try
            ControlClient.request!(removed_client, Heart.HeartCommand(:status);
                deadline=ControlClient.monotonic() + 8, check=check_owner)
        catch error
            error
        end
        wait_proof(() -> endpoint.pending !== nothing, 5, "removed-client ticket staging"; check=check_owner)
        removed_ticket = endpoint.pending
        with_thread_loop_lock(removed_client.loop) do _
            close(something(removed_client.marker))
        end
        wait_proof(() -> istaskdone(removed_task), 5, "removed-client unknown outcome"; check=check_owner)
        @test fetch(removed_task) isa ControlClient.UnknownOutcome
        @test endpoint.last_token == removed_ticket.header.token
        @test state.effects == effects_before_removal
        run_effects[] = true
        wait_proof(() -> endpoint.pending === nothing, 5, "removed ticket retirement"; check=check_owner)
        @test state.effects == effects_before_removal
        @test state.generation == next_snapshot.generation

        # Core loss after admission is also unknown; no reconnect or retry is issued.
        transport_client = connect()
        push!(clients, transport_client)
        run_effects[] = false
        effects_before_transport = state.effects
        transport_task = @async try
            ControlClient.request!(transport_client, Heart.HeartCommand(:status);
                deadline=ControlClient.monotonic() + 10,
                check=()->nothing)
        catch error
            error
        end
        wait_proof(() -> endpoint.pending !== nothing, 5, "transport-loss ticket staging"; check=owner_check)
        staged_token = endpoint.pending.header.token
        stop_proof_child!(daemon, "private PipeWire core for transport-loss case")
        wait_proof(() -> istaskdone(transport_task), 5, "transport-loss unknown outcome")
        @test fetch(transport_task) isa ControlClient.UnknownOutcome
        @test endpoint.last_token == staged_token
        @test state.effects == effects_before_transport
        @test state.generation == next_snapshot.generation

        report_hashes = Dict(basename(path)=>bytes2hex(sha256(read(path)))
            for path in readdir(report_root; join=true) if endswith(path, ".json"))
        write(joinpath(evidence, "summary.json"), JSON3.write(Dict(
            "owner_pid"=>getpid(), "endpoint_instance"=>owner_instance,
            "endpoint_node"=>OWNER_NAME, "profile"=>"pipewireao.rtc.heart/1",
            "controller_instance"=>client.marker_instance,
            "controller_global_id"=>client.identity.global_id,
            "controller_serial"=>client.identity.serial,
            "generations"=>[first_snapshot.generation, next_snapshot.generation],
            "child_pids"=>[first_snapshot.child_pid, next_snapshot.child_pid],
            "generation_report_sha256"=>report_hashes,
            "checks"=>["exact owner PID and endpoint instance admission",
                "wrong PID, endpoint instance and owner profile rejected",
                "fresh status and saved report hash verified",
                "negative no-snapshot completion preserved Ready owner and child",
                "reset completion replaced child and advanced generation",
                "health fence rejected prior generation snapshot",
                "post-reset negative None completion retained Ready but required fresh status",
                "controller removal unknown outcome with no retry/effect",
                "core transport loss unknown outcome with no retry/effect"],
            "child"=>"sleep subprocess only; not HEART executable",
            "vendor_heart_or_science_claim"=>false)))
        println("NATIVE_HEART_CLIENT_EVIDENCE=$evidence")
    finally
        quit[] = true
        if dispatcher !== nothing && !istaskdone(dispatcher)
            try wait(dispatcher) catch end
        end
        foreach(client -> try close(client) catch end, reverse(clients))
        endpoint === nothing || try close(endpoint) catch end
        if loop !== nothing
            with_thread_loop_lock(loop) do _
                for resource in (core, context)
                    resource === nothing || try close(resource) catch end
                end
            end
            try close(loop) catch end
        end
        child = state.child
        if child !== nothing && !process_exited(child)
            try stop_proof_child!(child, "fixture HEART sleep child") catch end
        end
        isdir(report_root) && foreach(path -> cp(path, joinpath(evidence, basename(path)); force=true),
            readdir(report_root; join=true))
    end
end

const EVIDENCE_ROOT = get(ENV, "NATIVE_HEART_EVIDENCE",
    joinpath(homedir(), ".cache", "rtc-live-controls-20261005"))
const EVIDENCE = mkpath(joinpath(EVIDENCE_ROOT, "native-heart-client-$(time_ns())"))

@testset "native HEART owner client on a private core" begin
    with_control_private_core((socket, directory, daemon) -> begin
        run_native_heart_client_proof(socket, directory, daemon, EVIDENCE)
    end; check_running=false)
end

@testset "native HEART Preparing, connect and shutdown lifecycle" begin
    with_control_private_core((socket, _, daemon) -> begin
        run_native_heart_lifecycle_proof(socket, daemon)
    end; check_running=false)
end
