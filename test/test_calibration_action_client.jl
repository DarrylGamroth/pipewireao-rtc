module CalibrationActionClientTests
using Test, PipeWireAORTC
import Clocks
const CalibrationActionClient = PipeWireAORTC.CalibrationActionClient
const Generic = PipeWireAORTC.ControlClient
const Codec = PipeWireAORTC.CalibrationActionCodec
const Lifecycle = PipeWireAORTC.AcquisitionLifecycleCodec
const Envelope = PipeWireAORTC.ControlCodec
mutable struct FakeConnection
    answer::Any
    failure::Any
    commands::Vector{Any}
    closed::Bool
    clock::Clocks.CachedNanoClock
end
function Generic.request!(fake::FakeConnection, command; deadline, check)
    check()
    fake.closed && throw(Generic.UnknownOutcome("closed fake client"))
    push!(fake.commands, command)
    fake.failure === nothing || throw(fake.failure)
    return fake.answer
end
Base.close(fake::FakeConnection) = (fake.closed = true; nothing)
struct OversizedFigure <: AbstractVector{Float64} end
Base.size(::OversizedFigure) = (4096,)
Base.getindex(::OversizedFigure, ::Int) =
    error("oversized figure was read before capacity validation")
const binding = CalibrationActionClient.Binding(
    "/tmp/private-core", "owner.actions", UInt32(7), Int64(42)
)
const identity = Envelope.ControllerIdentity(UInt32(7), typemax(UInt64), Int64(11))
header(op, result = Int32(0)) =
    Envelope.ReplyHeader(identity, Int64(42), Int64(1), UInt32(op), result)
function connection(
    result; op = 1, run = typemax(UInt64), serial = UInt64(1), transport = Int32(0)
)
    reply = Codec.Completion(
        header(op, transport), Lifecycle.Connected, run, serial, result, ""
    )
    fake = FakeConnection(reply, nothing, Any[], false, Clocks.CachedNanoClock(-10))
    return CalibrationActionClient.Connection(
        fake,
        binding,
        typemax(UInt64),
        UInt64(0),
        Int64(1_000_000_000),
        2,
        Dict{String,Any}[],
        false,
    )
end
function change_request!(supplied::AbstractDict)
    supplied["figure"][1] = 99
    supplied["kind"] = "changed"
end
change_request!(supplied::Codec.Adopt) = (supplied.figure[1] = 99)
@testset "native calibration action client preserves correlation and known outcomes" begin
    cursor = Codec.AcquisitionCursor(typemax(UInt64), UInt64(1) << 63, UInt64(0), UInt64(0))
    client = connection(Codec.Held(cursor))
    answer = CalibrationActionClient.request!(client, Dict("kind" => "hold"), "held")
    @test answer["cursor"]["domain"] == typemax(UInt64)
    @test only(client.client.commands).run == typemax(UInt64)
    @test only(client.client.commands).serial == 1
    @test client.can_restore && length(client.records) == 1
    @test client.records[1]["reply"]["run"] == typemax(UInt64)
    for reason in
        (Codec.Endpoint, Codec.Cancelled, Codec.ProbeClipped, Codec.InvalidEvidence)
        client = connection(Codec.Failed(reason))
        @test_throws ArgumentError CalibrationActionClient.request!(
            client, Codec.Hold(), "held"
        )
        @test client.can_restore == (reason === Codec.InvalidEvidence)
        @test !client.client.closed
    end
    client = connection(Codec.Released(); op = 7)
    @test CalibrationActionClient.request!(client, Codec.Release(), "released")["kind"] ==
        "released"
    @test length(client.records) == 1
    close(client)
    @test client.client.closed
end
@testset "completed calibration evidence owns its request and reply data" begin
    cursor = Codec.AcquisitionCursor(1, 1, 0, 0)
    for supplied in (
        Dict("kind" => "adopt", "probe" => 0, "figure" => Float32[1, 2]),
        Codec.Adopt(UInt32(0), Float32[1, 2]),
    )
        client = connection(Codec.Adopted(cursor, Float32[1, 2], false); op = 2)
        result = CalibrationActionClient.complete!(client, supplied)
        change_request!(supplied)
        result.figure[2] = 99
        evidence = only(client.records)
        @test evidence["request"]["action"]["kind"] == "adopt"
        @test evidence["request"]["action"]["figure"] == Float32[1, 2]
        @test evidence["reply"]["result"]["figure"] == Float32[1, 2]
    end
    exposure = Codec.Exposure(1, 1, 1, 0, 1)
    client = connection(Codec.Responses(Float32[3, 4], [exposure], true); op = 4)
    action = Codec.Collect(UInt32(0), cursor, UInt32(2), UInt32(1))
    result = CalibrationActionClient.complete!(client, action)
    result.values[1] = 99
    empty!(result.exposures)
    retained = only(client.records)["reply"]["result"]
    @test retained["values"] == Float32[3, 4]
    @test only(retained["exposures"])["sequence"] == 1
end

@testset "unknown native outcomes retire the action client" begin
    cursor = Codec.AcquisitionCursor(1, 1, 0, 0)
    for client in (
        connection(Codec.Held(cursor); run = UInt64(2)),
        connection(Codec.Held(cursor); serial = UInt64(2)),
        connection(nothing; transport = Int32(-110)),
        connection(Codec.Released()),
        connection(Codec.Adopted(cursor, Float32[1], false); op = 2),
    )
        requested =
            client.client.answer.header.operation == 2 ?
            Codec.Adopt(UInt32(0), Float32[1, 2]) : Codec.Hold()
        @test_throws Generic.UnknownOutcome CalibrationActionClient.request!(
            client, requested, "held"
        )
        @test !client.can_restore && client.client.closed
    end
    client = connection(Codec.Held(cursor))
    client.client.failure = Generic.UnknownOutcome("private core disconnected")
    @test_throws Generic.UnknownOutcome CalibrationActionClient.request!(
        client, Codec.Hold(), "held"
    )
    @test client.client.closed && !client.can_restore
    @test_throws Generic.UnknownOutcome CalibrationActionClient.request!(
        client, Codec.Hold(), "held"
    )
    @test length(client.client.commands) == 1 # Never submit a retry.
end
@testset "local validation does not consume or submit native requests" begin
    client = connection(Codec.Released(); op = 7)
    for value in (
        Dict("kind" => "adopt", "probe" => 0, "figure" => [NaN]),
        Dict("kind" => "adopt", "probe" => true, "figure" => [1]),
        Dict("kind" => "hold", "extra" => 1),
        Dict("kind" => "unknown"),
        Dict(
            "kind" => "restore",
            "figure" => [1],
            "rule" => Dict("kind" => "model_time", "duration_ns" => 0),
        ),
    )
        @test_throws ArgumentError CalibrationActionClient.request!(
            client, value, "released"
        )
    end
    @test client.serial == 0 && isempty(client.client.commands)
    for value in (
        Dict("kind" => "adopt", "probe" => 0, "figure" => OversizedFigure()),
        Dict(
            "kind" => "restore",
            "figure" => OversizedFigure(),
            "rule" => Dict("kind" => "immediate"),
        ),
    )
        @test_throws ArgumentError CalibrationActionClient.request!(
            client, value, "released"
        )
    end
    @test client.serial == 0 && isempty(client.client.commands)
    client.serial = typemax(UInt64)
    @test_throws OverflowError CalibrationActionClient.request!(
        client, Codec.Release(), "released"
    )
    @test isempty(client.client.commands)
    for values in (("remote", "node", 0, 1), ("remote", "node", 1, 0))
        @test_throws ArgumentError CalibrationActionClient.Binding(values...)
    end
end

@testset "zero Collect retains known correlated responses for caller validation" begin
    cursor = Codec.AcquisitionCursor(1, 1, 0, 0)
    exposure = Codec.Exposure(1, 1, 1, 0, 1)
    client = connection(Codec.Responses(Float32[], [exposure], true); op = 4)
    supplied = Dict(
        "kind" => "collect",
        "probe" => 0,
        "after" => Dict("domain" => 1, "generation" => 1, "sequence" => 0, "model_ns" => 0),
        "measurements" => 0,
        "frames" => 1,
    )
    result = CalibrationActionClient.complete!(client, supplied)
    @test isempty(result.values) && length(result.exposures) == 1 && result.valid
    @test only(client.client.commands).action.measurements == 0
    @test client.can_restore
    for (measurements, frames, result) in (
        (1, 1, Codec.Responses(Float32[], [exposure], true)),
        (0, 1, Codec.Responses(Float32[1], [exposure], true)),
        (0, 2, Codec.Responses(Float32[], [exposure], true)),
    )
        client = connection(result; op = 4)
        action = Codec.Collect(UInt32(0), cursor, UInt32(measurements), UInt32(frames))
        # The terminal outcome is known. Scientific dimensions are checked by
        # the caller, which must retain explicit restoration on invalid evidence.
        @test CalibrationActionClient.complete!(client, action) === result
        @test !client.client.closed && client.can_restore
    end
end
end
