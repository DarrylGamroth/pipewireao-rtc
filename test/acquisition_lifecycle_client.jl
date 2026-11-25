using Test, PipeWireAO, PipeWireAORTC

include("control_private_core.jl")

const Codec = PipeWireAORTC.AcquisitionLifecycleCodec
const Caller = PipeWireAORTC.AcquisitionLifecycleClient
const Generic = PipeWireAORTC.ControlClient
const Endpoint = PipeWireAORTC.ControlEndpoint

function stub_service_once!(runtime)
    Endpoint.has_pending(runtime) || return nothing
    Endpoint.poll!(runtime)
    return Endpoint.take!(runtime)
end

mutable struct StubAcquisition
    lifecycle::Codec.ColdLifecycle
    instrument::Codec.Instrument
    cursor::Union{Nothing,Codec.AcquisitionCursor}
    report_cursor::Union{Nothing,Codec.AcquisitionCursor}
    running::Bool
    completed::Bool
    held::Bool
    restored::Bool
    window::Union{Nothing,UInt64}
    effects::Int
end

function stub_snapshot(profile, state::StubAcquisition)
    phase = if state.lifecycle === Codec.Prepared
        "initial"
    elseif state.lifecycle === Codec.Stopped
        (profile isa Codec.CalibrationLifecycleProfile ? "released" : "restored")
    elseif profile isa Codec.CalibrationLifecycleProfile
        "held"
    else
        "correcting"
    end
    return Codec.Snapshot(
        state.instrument,
        state.cursor,
        state.report_cursor,
        state.running,
        state.completed,
        phase,
        state.held,
        state.restored,
        state.window,
    )
end

function stub_effect!(profile, state::StubAcquisition, ticket, report_path)
    operation = ticket.command
    result = Int32(0)
    message = ""
    if operation isa Codec.LifecycleCommand{:connect}
        state.lifecycle = Codec.Connected
        state.cursor = Codec.AcquisitionCursor(
            typemax(UInt64), UInt64(1) << 63, UInt64(4), typemax(UInt64)
        )
        state.held = true
        state.window = profile isa Codec.CorrectionLifecycleProfile ? UInt64(1) : nothing
    elseif operation isa Codec.LifecycleCommand{:pause}
        state.running = false
    elseif operation isa Codec.LifecycleCommand{:resume}
        old = something(state.cursor)
        # Fixture artifact only: publication precedes the separate live cursor.
        open(report_path, "w") do io
            write(io, "synthetic report cursor $(old.sequence)\n")
        end
        state.report_cursor = old
        state.cursor = Codec.AcquisitionCursor(
            old.domain, old.generation, old.sequence + UInt64(1), old.model_ns
        )
        state.running = true
    elseif operation isa Codec.LifecycleCommand{:reset}
        if profile isa Codec.CalibrationLifecycleProfile
            result = Int32(-95)
            message = "calibration reset requires a new owner"
        else
            state.running && error("stub correction reset requires pause")
            old = something(state.cursor)
            state.cursor = Codec.AcquisitionCursor(
                old.domain, old.generation + UInt64(1), UInt64(0), UInt64(0)
            )
            state.window = something(state.window) + UInt64(1)
        end
    elseif operation isa Codec.LifecycleCommand{:shutdown}
        state.running = false
        state.held = false
        state.restored = true
        state.lifecycle = Codec.Stopped
    elseif !(operation isa Codec.LifecycleCommand{:status})
        error("undeclared stub operation")
    end
    state.effects += 1
    return result, message
end

function check_disappearing_controller(runtime, client, daemon, check)
    native = client.client
    name = Generic.CONTROLLER_NODE_PREFIX * "test-disappearing"
    marker = with_thread_loop_lock(native.loop) do _
        filter = Filter(native.core, name; properties = Dict("node.name" => name))
        connect!(filter; flags = FILTER_ASYNC | FILTER_INACTIVE)
        filter
    end
    lookup() = find_globals(something(runtime.endpoint.registry); properties = ("node.name" => name,))
    daemon_stopped = false
    try
        wait_proof(() -> !isempty(lookup()), 3, "disappearing controller published"; check)
        local_id = with_thread_loop_lock(runtime.loop) do _
            global_id = only(lookup()).id
            with_thread_loop_lock(native.loop) do _
                close(marker)
            end
            # Confirm deletion on the publishing connection while the owner
            # still holds the earlier registry view, then submit its stale bind.
            roundtrip(native.core)
            run(`kill -STOP $(getpid(daemon))`)
            daemon_stopped = true
            wait_proof(3, "private core suspended"; check) do
                occursin(r"(?m)^State:\s+T", read("/proc/$(getpid(daemon))/status", String))
            end
            @test only(lookup()).id == global_id
            Endpoint.poll!(runtime)

            endpoint = runtime.endpoint
            candidate = only(filter(c -> c.global_id == global_id, endpoint.controllers))
            admitted = only(filter(c -> c.identity == native.identity, endpoint.controllers))
            missing = PipeWireError(:pw_core, -Base.Libc.ENOENT)
            @test Endpoint.controller_bind_failed(endpoint, candidate.proxy_id, missing)
            @test Endpoint.controller_bind_failed(
                endpoint, candidate.proxy_id, PipeWireError(:pw_core, -Base.Libc.ESTALE)
            )
            @test !Endpoint.controller_bind_failed(endpoint, admitted.proxy_id, missing)
            @test !Endpoint.controller_bind_failed(endpoint, UInt32(0), missing)
            @test !Endpoint.controller_bind_failed(endpoint, typemax(UInt32), missing)
            @test !Endpoint.controller_bind_failed(
                endpoint, candidate.proxy_id, PipeWireError(:pw_core, -Base.Libc.EPIPE)
            )
            candidate.proxy_id
        end
        # The server has sent the withdrawal but cannot reply to the stale bind.
        # The next owner poll must release the candidate's admission state while
        # keeping its proxy alive through the pending bind reply.
        wait_proof(() -> isempty(lookup()), 3, "controller global withdrawn"; check)
        Endpoint.poll!(runtime)
        with_thread_loop_lock(runtime.loop) do _
            endpoint = runtime.endpoint
            @test all(c -> c.proxy_id != local_id, endpoint.controllers)
            @test endpoint.pending_controller_binds[local_id].node !== nothing
        end
        run(`kill -CONT $(getpid(daemon))`)
        daemon_stopped = false
        sequence = with_thread_loop_lock(runtime.loop) do _
            PipeWireAO.sync!(runtime.core)
        end
        wait_proof(3, "failed bind and RemoveID delivered"; check) do
            with_thread_loop_lock(runtime.loop) do _
                runtime.acknowledged_sequence[] == sequence &&
                    !haskey(runtime.endpoint.pending_controller_binds, local_id)
            end
        end
        Endpoint.poll!(runtime)
        with_thread_loop_lock(runtime.loop) do _
            @test !Endpoint.controller_bind_failed(
                runtime.endpoint, local_id, PipeWireError(:pw_core, -Base.Libc.ENOENT)
            )
            @test Endpoint.controller_present(runtime.endpoint, something(native.identity))
        end
    finally
        daemon_stopped && run(`kill -CONT $(getpid(daemon))`)
        with_thread_loop_lock(native.loop) do _
            close(marker)
        end
    end
    return nothing
end

function run_stub_profile(socket, directory, daemon, profile, instrument, suffix)
    instance = Int64(time_ns() % UInt64(typemax(Int64) - 2)) + 1
    node = "test.native.acquisition.$suffix"
    runtime = Endpoint.Transport(profile, socket, node, instance, Codec.Preparing)
    state = StubAcquisition(
        Codec.Preparing,
        instrument,
        nothing,
        nothing,
        false,
        false,
        false,
        false,
        nothing,
        0,
    )
    report_path = joinpath(directory, "stub-report-$suffix.txt")
    quit = Ref(false)
    allow_take = Ref(true)
    worker = nothing
    client = nothing
    worker_failure = Ref{Any}(nothing)
    check_worker() = begin
        worker_failure[] === nothing || throw(worker_failure[])
        Base.process_exited(daemon) && error("private core exited")
        nothing
    end
    deadline(seconds = 10.0) = Generic.monotonic() + seconds
    try
        @test runtime.endpoint.lifecycle === Codec.Preparing
        # Warm the exact service path and show an idle scientific hook can
        # return without polling Registry or allocating Julia heap storage.
        # Exclude startup callbacks throughout the idle precondition and
        # measurement; they can wake the hook and allocate independently.
        with_thread_loop_lock(runtime.loop) do _
            stub_service_once!(runtime)
            stub_service_once!(runtime)
            @test !Endpoint.has_pending(runtime)
            @test (@allocated Endpoint.has_pending(runtime)) == 0
            @test (@allocated stub_service_once!(runtime)) == 0
        end
        worker = @async try
            ready_at = Generic.monotonic() + 0.1
            while !quit[]
                if state.lifecycle === Codec.Preparing && Generic.monotonic() >= ready_at
                    state.lifecycle = Codec.Prepared
                    Endpoint.state!(runtime.endpoint, Codec.Prepared)
                end
                ticket = allow_take[] ? stub_service_once!(runtime) : nothing
                if ticket !== nothing
                    Endpoint.check_ticket(runtime.endpoint, ticket)
                    result, message = stub_effect!(profile, state, ticket, report_path)
                    state.lifecycle == runtime.endpoint.lifecycle ||
                        Endpoint.state!(runtime.endpoint, state.lifecycle)
                    Endpoint.complete!(
                        runtime,
                        ticket,
                        state.lifecycle,
                        stub_snapshot(profile, state);
                        result,
                        message,
                    )
                    if ticket.command isa Codec.LifecycleCommand{:shutdown}
                        Endpoint.flush_terminal!(
                            runtime, ticket.deadline; check = check_worker
                        )
                        quit[] = true
                    end
                end
                sleep(0.002)
            end
        catch error
            worker_failure[] = error
            rethrow()
        end
        client = Caller.connect(
            profile,
            socket,
            node,
            getpid(),
            instance,
            instrument;
            deadline = deadline(),
            check = check_worker,
        )
        @test client.client.observation.capability.lifecycle === Codec.Prepared
        @test state.effects == 1 # Fresh Status after Prepared, not retained enum data.
        @test Caller.status(client; deadline = deadline(), check = check_worker).snapshot.cursor ===
            nothing

        if profile isa Codec.CorrectionLifecycleProfile
            allow_take[] = false
            try
                check_disappearing_controller(runtime, client, daemon, check_worker)
            finally
                allow_take[] = true
            end
        end

        wrong_profile =
            profile isa Codec.CalibrationLifecycleProfile ? Codec.CORRECTION_PROFILE :
            Codec.CALIBRATION_PROFILE
        @test_throws Generic.UnknownOutcome Caller.connect(
            wrong_profile,
            socket,
            node,
            getpid(),
            instance,
            instrument;
            deadline = deadline(2),
            check = check_worker,
        )
        wrong_instrument = instrument === Codec.Classic ? Codec.Copper : Codec.Classic
        @test_throws Generic.UnknownOutcome Caller.connect(
            profile,
            socket,
            node,
            getpid(),
            instance,
            wrong_instrument;
            deadline = deadline(),
            check = check_worker,
        )

        connected = Caller.connect_owner!(
            client; deadline = deadline(), check = check_worker
        )
        @test connected.lifecycle === Codec.Connected
        @test connected.snapshot.cursor.generation == UInt64(1) << 63
        @test connected.snapshot.cursor.domain == typemax(UInt64)
        @test connected.snapshot.report_cursor === nothing
        @test connected.snapshot.window ==
            (profile isa Codec.CorrectionLifecycleProfile ? UInt64(1) : nothing)
        resumed = Caller.request!(
            client, :resume; deadline = deadline(), check = check_worker
        )
        @test resumed.snapshot.running
        @test resumed.snapshot.cursor.sequence == 5
        @test resumed.snapshot.report_cursor.sequence == 4
        @test isfile(report_path)
        current = Caller.status(client; deadline = deadline(), check = check_worker)
        @test current.snapshot.cursor.sequence == 5
        @test current.snapshot.report_cursor.sequence == 4
        @test Caller.request!(
            client, :pause; deadline = deadline(), check = check_worker
        ).snapshot.running == false
        before_reset = state.cursor
        reset = Caller.request!(client, :reset; deadline = deadline(), check = check_worker)
        if profile isa Codec.CalibrationLifecycleProfile
            @test reset.header.result == -95
            @test reset.snapshot.cursor == before_reset
            @test reset.snapshot.held
        else
            @test reset.header.result == 0
            @test reset.snapshot.cursor.generation == before_reset.generation + 1
            @test reset.snapshot.report_cursor == current.snapshot.report_cursor
            @test reset.snapshot.window == 2
        end

        # A queued request expires without owner effects or a retry.
        allow_take[] = false
        before_expiry = state.effects
        expired = @async try
            Caller.request!(
                client, :status; deadline = deadline(0.25), check = check_worker
            )
        catch error
            error
        end
        wait_proof(
            () -> runtime.endpoint.pending !== nothing,
            3,
            "staged expired request";
            check = check_worker,
        )
        @test state.effects == before_expiry
        wait_proof(() -> istaskdone(expired), 3, "client expired"; check = check_worker)
        @test fetch(expired) isa Generic.UnknownOutcome
        allow_take[] = true
        wait_proof(
            () -> runtime.endpoint.pending === nothing,
            3,
            "owner retired expired request";
            check = check_worker,
        )
        @test state.effects == before_expiry
        close(client)
        client = Caller.connect(
            profile,
            socket,
            node,
            getpid(),
            instance,
            instrument;
            deadline = deadline(),
            check = check_worker,
        )

        # Removing the actual controller marker retires accepted work.
        allow_take[] = false
        before_removal = state.effects
        removed = @async try
            Caller.request!(client, :status; deadline = deadline(), check = check_worker)
        catch error
            error
        end
        wait_proof(
            () -> runtime.endpoint.pending !== nothing,
            3,
            "staged removed request";
            check = check_worker,
        )
        @test state.effects == before_removal
        removed_identity = client.client.identity
        with_thread_loop_lock(client.client.loop) do _
            close(client.client.marker)
        end
        wait_proof(
            () -> !Endpoint.controller_present(runtime.endpoint, removed_identity),
            3,
            "owner observed removed controller";
            check = check_worker,
        )
        allow_take[] = true
        wait_proof(
            () -> istaskdone(removed), 3, "removed caller outcome"; check = check_worker
        )
        @test fetch(removed) isa Generic.UnknownOutcome
        wait_proof(
            () -> runtime.endpoint.pending === nothing,
            3,
            "owner retired removed request";
            check = check_worker,
        )
        @test state.effects == before_removal
        close(client)
        client = Caller.connect(
            profile,
            socket,
            node,
            getpid(),
            instance,
            instrument;
            deadline = deadline(),
            check = check_worker,
        )
        @test_throws Generic.UnknownOutcome Endpoint.flush_terminal!(
            runtime, deadline(-0.1)
        )
        shutdown = Caller.request!(
            client, :shutdown; deadline = deadline(), check = check_worker
        )
        @test shutdown.lifecycle === Codec.Stopped
        @test shutdown.snapshot.restored && !shutdown.snapshot.held
        wait_proof(
            () -> istaskdone(worker),
            3,
            "terminal synchronized stub owner";
            check = check_worker,
        )
        fetch(worker)
    finally
        quit[] = true
        worker === nothing || try
            wait(worker)
        catch
        end
        client === nothing || try
            close(client)
        catch
        end
        close(runtime)
        @test runtime.closed
        @test runtime.endpoint.closed
        @test close(runtime) === nothing
    end
end

@testset "native acquisition lifecycle cold private-core helpers" begin
    with_control_private_core() do socket, directory, daemon
        chmod(dirname(socket), 0o700)
        run_stub_profile(
            socket,
            directory,
            daemon,
            Codec.CALIBRATION_PROFILE,
            Codec.Classic,
            "calibration",
        )
        run_stub_profile(
            socket, directory, daemon, Codec.CORRECTION_PROFILE, Codec.Copper, "correction"
        )
    end
end
