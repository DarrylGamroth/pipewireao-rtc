# Native protocol/effect dispatch only; the instrument optical selector is separate.
using Test, PipeWireAO, PipeWireAORTC
Base.include(@__MODULE__, joinpath(@__DIR__, "control_private_core.jl"))
const Server = PipeWireAORTC.CalibrationEndpoint
const Actions = PipeWireAORTC.CalibrationActionCodec
const ControlClient = PipeWireAORTC.ControlClient

mutable struct Effects
    actions::Vector{DataType}
    tasks::Vector{Task}
    closed::Bool
    outcome::Symbol
end
Effects(actions, tasks, closed) = Effects(actions, tasks, closed, :success)
Base.close(effects::Effects) = (effects.closed = true; nothing)
function (effects::Effects)(action, deadline::Int64)
    push!(effects.actions, typeof(action))
    push!(effects.tasks, current_task())
    if effects.outcome === :failed
        effects.outcome = :success
        return Actions.Failed(Actions.InvalidEvidence)
    elseif effects.outcome === :wrong
        return Actions.Released()
    elseif effects.outcome === :exception
        error("calibration effect failed")
    end
    cursor = Actions.AcquisitionCursor(UInt64(1), UInt64(1), UInt64(0), UInt64(0))
    action isa Actions.Hold && return Actions.Held(cursor)
    action isa Actions.Adopt && return Actions.Adopted(cursor, copy(action.figure), false)
    action isa Actions.Settle && return Actions.Settled(cursor)
    action isa Actions.Restore && return Actions.Restored(copy(action.figure), false)
    action isa Actions.Release && return Actions.Released()
    error("unsupported test action")
end

@testset "native action failure retains its accepted run and phase" begin
    with_control_private_core() do remote, directory, daemon
        chmod(dirname(remote), 0o700)
        effects = Effects(DataType[], Task[], false, :failed)
        server = Server.Endpoint(
            remote, "test.calibration.failed-action", Int64(43), effects
        )
        serving = @async try
            Server.serve!(server; deadline = ControlClient.monotonic() + 20)
        catch error
            error
        end
        client = nothing
        try
            client = ControlClient.connect(
                Actions.PROFILE,
                remote,
                "test.calibration.failed-action",
                getpid(),
                43;
                deadline = ControlClient.monotonic() + 10,
            )
            request(serial, action) = ControlClient.request!(
                client,
                Actions.Command(UInt64(1), UInt64(serial), action);
                deadline = ControlClient.monotonic() + 5,
            ).result
            @test request(1, Actions.Hold()) isa Actions.Failed
            @test server.phase === :Prepared && server.run == 1 && server.serial == 1
            @test request(1, Actions.Hold()) isa Actions.Failed
            @test effects.actions == [Actions.Hold]
            @test request(2, Actions.Hold()) isa Actions.Held
            @test request(3, Actions.Restore(Float32[0, 0], Actions.Immediate())) isa
                Actions.Restored
            @test request(4, Actions.Release()) isa Actions.Released
            close(client)
            client = nothing
            @test fetch(serving) === nothing && server.phase === :Released
            @test all(task -> task === serving, effects.tasks)
        finally
            client === nothing || close(client)
            close(server)
        end
        @test effects.closed
    end
end

@testset "wrong or unknown action results fence the effect owner without retry" begin
    for outcome in (:wrong, :exception)
        with_control_private_core() do remote, directory, daemon
            chmod(dirname(remote), 0o700)
            effects = Effects(DataType[], Task[], false, outcome)
            server = Server.Endpoint(
                remote, "test.calibration.unknown-action", Int64(44), effects
            )
            serving = @async try
                Server.serve!(server; deadline = ControlClient.monotonic() + 20)
            catch error
                error
            end
            client = nothing
            try
                client = ControlClient.connect(
                    Actions.PROFILE,
                    remote,
                    "test.calibration.unknown-action",
                    getpid(),
                    44;
                    deadline = ControlClient.monotonic() + 10,
                )
                @test_throws ControlClient.UnknownOutcome ControlClient.request!(
                    client,
                    Actions.Command(UInt64(1), UInt64(1), Actions.Hold());
                    deadline = ControlClient.monotonic() + 5,
                )
                @test fetch(serving) isa Exception
                @test server.phase === :Fault && server.run == 1 && server.serial == 1
                @test effects.actions == [Actions.Hold] && effects.closed
                @test server.ingress.closed
                @test server.protocol.command === nothing
            finally
                client === nothing || close(client)
                close(server)
            end
        end
    end
end

@testset "native calibration serializes effects without a polling client hook" begin
    with_control_private_core() do remote, directory, daemon
        chmod(dirname(remote), 0o700)
        effects = Effects(DataType[], Task[], false)
        server = Server.Endpoint(remote, "test.calibration.owner", Int64(41), effects)
        serving = @async try
            Server.serve!(server; deadline = ControlClient.monotonic() + 20)
        catch error
            error
        end
        client = nothing
        try
            client = ControlClient.connect(
                Actions.PROFILE,
                remote,
                "test.calibration.owner",
                getpid(),
                41;
                deadline = ControlClient.monotonic() + 10,
            )
            request(run, serial, action) = ControlClient.request!(
                client,
                Actions.Command(UInt64(run), UInt64(serial), action);
                deadline = ControlClient.monotonic() + 5,
            ).result
            @test request(1, 1, Actions.Hold()) isa Actions.Held
            @test request(2, 2, Actions.Adopt(UInt32(0), Float32[1, 2])) isa Actions.Failed
            @test request(1, 1, Actions.Restore(Float32[0, 0], Actions.Immediate())) isa
                Actions.Failed
            @test effects.actions == [Actions.Hold]
            adopted = request(1, 2, Actions.Adopt(UInt32(0), Float32[1, 2]))
            @test adopted.figure == Float32[1, 2]
            @test request(1, 3, Actions.Release()) isa Actions.Failed
            @test request(
                1, 4, Actions.Settle(UInt32(0), adopted.cursor, Actions.Immediate())
            ) isa Actions.Settled
            @test request(1, 5, Actions.Restore(Float32[0, 0], Actions.Immediate())) isa
                Actions.Restored
            @test request(1, 6, Actions.Release()) isa Actions.Released
            close(client)
            client = nothing
            @test fetch(serving) === nothing
            @test all(task -> task === serving, effects.tasks)
            @test server.phase === :Released
        finally
            client === nothing || close(client)
            close(server)
        end
        @test effects.closed
    end
end

@testset "idle controller loss fences effects without recovery or another run" begin
    with_control_private_core() do remote, directory, daemon
        chmod(dirname(remote), 0o700)
        effects = Effects(DataType[], Task[], false)
        server = Server.Endpoint(remote, "test.calibration.interrupted", Int64(42), effects)
        serving = @async try
            Server.serve!(server; deadline = ControlClient.monotonic() + 20)
        catch error
            error
        end
        client = nothing
        try
            client = ControlClient.connect(
                Actions.PROFILE,
                remote,
                "test.calibration.interrupted",
                getpid(),
                42;
                deadline = ControlClient.monotonic() + 10,
            )
            reply = ControlClient.request!(
                client,
                Actions.Command(UInt64(1), UInt64(1), Actions.Hold());
                deadline = ControlClient.monotonic() + 5,
            )
            @test reply.result isa Actions.Held
            close(client)
            client = nothing
            @test fetch(serving) isa Exception
            @test effects.actions == [Actions.Hold]
            @test effects.closed
            @test server.phase === :Fault
            @test server.ingress.closed
            @test_throws InvalidStateException Server.serve!(
                server; deadline = ControlClient.monotonic() + 1
            )
        finally
            client === nothing || close(client)
            close(server)
        end
    end
end
