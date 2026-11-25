using Test, PipeWireAORTC

const Runner = PipeWireAORTC.RunnerCodec
const Envelope = PipeWireAORTC.ControlCodec
const ActionClient = PipeWireAORTC.CalibrationActionClient
const Parameters = PipeWireAORTC.ParameterSource
const Offsets = PipeWireAORTC.PhysicalOffsets

@testset "runner scalar storage and request validation" begin
    identity = Envelope.ControllerIdentity(UInt32(7), UInt64(11), Int64(13))
    header = Envelope.RequestHeader(
        identity, Int64(17), Int64(1), UInt32(13), Int64(1_000_000_000)
    )
    for (kind, value) in (
        (:bool, true),
        (:int, Int32(-1)),
        (:long, Int64(-2)),
        (:float, UInt32(0x80000000)),
        (:double, UInt64(0x8000000000000000)),
        (:id, UInt32(3)),
        (:string, "setting"),
    )
        scalar = Runner.RunnerScalar(kind, value)
        @test fieldtype(typeof(scalar), :value) === typeof(value)
        request = Runner.RunnerCommand(
            :properties_set, "graph", Dict("node.property" => scalar)
        )
        _, decoded = Runner.decode_request(Runner.encode_request(header, request))
        @test decoded.args[2]["node.property"].kind === kind
        @test decoded.args[2]["node.property"].value === value
    end
    for (kind, value) in (
        (:bool, Int32(1)),
        (:int, true),
        (:long, Int32(1)),
        (:float, 1.0f0),
        (:double, UInt32(1)),
        (:id, Int32(1)),
        (:string, SubString("text", 1, 2)),
    )
        @test_throws ArgumentError("invalid runner scalar kind/value") Runner.RunnerScalar(
            kind, value
        )
    end
    @test_throws ArgumentError("properties must be a typed String=>RunnerScalar dictionary") Runner.encode_request(
        header,
        Runner.RunnerCommand(
            :properties_set,
            "graph",
            Dict{String,Any}("node.property" => Runner.RunnerScalar(:bool, true)),
        ),
    )
end

@testset "boundary dispatch rejects invalid representation before conversion" begin
    for value in (true, 1.0, "1", nothing)
        @test_throws ArgumentError("calibration integer out of range") ActionClient._integer(
            value, 1, 5
        )
        @test_throws ArgumentError("physical offsets require positive bounded time limits") Offsets._calibration_time(
            value, Int64
        )
    end
    for version in (true, Int32(1), 1.0, "1", nothing)
        @test_throws ArgumentError("invalid parameter source configuration") Parameters._declaration_config(
            Dict("version" => version, "sources" => [])
        )
    end
    @test Parameters._declaration_config(Dict("version" => Int64(1), "sources" => [])) ===
        nothing
    for shape in ([true], [1.0], [-1], (1,))
        @test_throws ArgumentError("invalid parameter shape") Parameters._declaration_shape(
            shape
        )
    end
    @test Offsets.exposure_end(Int64(0), UInt64(1)) === Int64(1)
    @test_throws ArgumentError("invalid model exposure interval") Offsets.exposure_end(
        Int32(0), UInt64(1)
    )
    @test_throws ArgumentError("invalid model exposure interval") Offsets.exposure_end(
        Int64(0), Int64(1)
    )
end
