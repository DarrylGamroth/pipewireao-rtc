# Native protocol/effect dispatch only; the instrument optical selector is separate.
using Test, PipeWireAO, PipeWireAORTC
Base.include(@__MODULE__, joinpath(@__DIR__, "native_control_private_core.jl"))
const Server = PipeWireAORTC.NativeCalibrationEndpoint
const Actions = PipeWireAORTC.NativeCalibrationActionCodec
const Native = PipeWireAORTC.NativeControlClient

mutable struct Effects
    actions::Vector{DataType}
    tasks::Vector{Task}
    closed::Bool
end
Base.close(effects::Effects) = (effects.closed = true; nothing)
function (effects::Effects)(action, deadline)
    push!(effects.actions, typeof(action))
    push!(effects.tasks, current_task())
    cursor = Actions.AcquisitionCursor(UInt64(1), UInt64(1), UInt64(0), UInt64(0))
    action isa Actions.Hold && return Actions.Held(cursor)
    action isa Actions.Adopt && return Actions.Adopted(cursor, copy(action.figure), false)
    action isa Actions.Settle && return Actions.Settled(cursor)
    action isa Actions.Restore && return Actions.Restored(copy(action.figure), false)
    action isa Actions.Release && return Actions.Released()
    error("unsupported test action")
end

@testset "native calibration serializes effects without a polling client hook" begin
    with_control_private_core() do remote, directory, daemon
        chmod(dirname(remote), 0o700)
        effects = Effects(DataType[], Task[], false)
        server = Server.Endpoint(remote, "test.calibration.owner", Int64(41), effects)
        serving = @async try
            Server.serve!(server; deadline=Native.monotonic() + 20)
        catch error
            error
        end
        client = nothing
        try
            client = Native.connect(Actions.PROFILE, remote, "test.calibration.owner",
                getpid(), 41; deadline=Native.monotonic() + 10)
            request(run, serial, action) = Native.request!(client,
                Actions.Command(UInt64(run), UInt64(serial), action);
                deadline=Native.monotonic() + 5).result
            @test request(1, 1, Actions.Hold()) isa Actions.Held
            @test request(2, 2, Actions.Adopt(UInt32(0), Float32[1, 2])) isa Actions.Failed
            @test request(1, 1, Actions.Restore(Float32[0, 0], Actions.Immediate())) isa Actions.Failed
            @test effects.actions == [Actions.Hold]
            adopted = request(1, 2, Actions.Adopt(UInt32(0), Float32[1, 2]))
            @test adopted.figure == Float32[1, 2]
            @test request(1, 3, Actions.Release()) isa Actions.Failed
            @test request(1, 4, Actions.Settle(UInt32(0), adopted.cursor, Actions.Immediate())) isa Actions.Settled
            @test request(1, 5, Actions.Restore(Float32[0, 0], Actions.Immediate())) isa Actions.Restored
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
            Server.serve!(server; deadline=Native.monotonic()+20)
        catch error
            error
        end
        client = nothing
        try
            client = Native.connect(Actions.PROFILE, remote, "test.calibration.interrupted",
                getpid(), 42; deadline=Native.monotonic()+10)
            reply = Native.request!(client, Actions.Command(UInt64(1), UInt64(1), Actions.Hold());
                deadline=Native.monotonic()+5)
            @test reply.result isa Actions.Held
            close(client)
            client = nothing
            @test fetch(serving) isa Exception
            @test effects.actions == [Actions.Hold]
            @test effects.closed
            @test server.phase === :Fault
            @test server.ingress.closed
            @test_throws InvalidStateException Server.serve!(server; deadline=Native.monotonic()+1)
        finally
            client === nothing || close(client)
            close(server)
        end
    end
end
