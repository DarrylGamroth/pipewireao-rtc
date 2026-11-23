using Test, PipeWireAO, PipeWireAORTC

const Runner = PipeWireAORTC.RunnerCodec
const Codec = PipeWireAORTC.ControlCodec
const Parameter = PipeWireAORTC.ParameterSource
const Session = PipeWireAORTC.SessionCodec

@testset "Native parameter ndarray codec" begin
    format = NdArrayFormat(NdArray.F32_LE, (2, 3); layout = NdArray.COLUMN_MAJOR)
    controller = Codec.ControllerIdentity(UInt32(9), UInt64(11), Int64(13))
    operator = Codec.ControllerIdentity(UInt32(21), typemax(UInt64), Int64(23))
    header = Codec.RequestHeader(controller, Int64(24), Int64(25), UInt32(17), Int64(1_000_000))
    for data in (
        Float32[1, 2, 3, 4, 5, 6],
        Runner.ParameterStream(UInt32(30), typemax(UInt64), UInt32(31), UInt64(44)),
    )
        input = Runner.ParameterNdArray(format, "pipewireao/test-parameter/1", data)
        command = Runner.RunnerCommand(:parameter_ndarray, "graph", "reference", input)
        decoded_header, decoded = Runner.decode_request(Session.encode_request(header, command))
        @test decoded_header.operation == 17
        @test decoded.args[1:2] == ("graph", "reference")
        received = decoded.args[3]
        @test received.format == format
        @test received.schema == input.schema
        @test received.data == data
        forwarded = Parameter.NdArrayParameter("graph", "reference", input, operator)
        wire = Parameter.Client.encode_request(Parameter.PROFILE, header, forwarded)
        _, decoded_forward = Parameter.Client.decode_request(Parameter.PROFILE, wire)
        @test decoded_forward.controller == operator
        @test decoded_forward.parameter.data == data
        @test_throws ArgumentError Runner.decode_request(wire)
    end
    @test Runner.ParameterNdArray(format, "", zeros(Float32, 6)).schema === nothing
    @test_throws ArgumentError Runner.ParameterNdArray(format, nothing, Float32[1, 2])
    @test_throws ArgumentError Runner.ParameterNdArray(format, nothing, fill(Float32(NaN), 6))

    large_format = NdArrayFormat(NdArray.F32_LE, (134_217_728,); layout = NdArray.ROW_MAJOR)
    large = Runner.ParameterNdArray(
        large_format, nothing,
        Runner.ParameterStream(UInt32(30), UInt64(31), UInt32(32), UInt64(33)),
    )
    @test payload_size(large.format) == 512 * 1024 * 1024
    @test length(Session.encode_request(header, Runner.RunnerCommand(:parameter_ndarray, "graph", "reference", large)).data) < 1024
    @test_throws ArgumentError Runner.ParameterNdArray(
        NdArrayFormat(NdArray.F32_LE, (134_217_729,); layout = NdArray.ROW_MAJOR),
        nothing, large.data,
    )
    oversized_inline = Runner.ParameterNdArray(
        NdArrayFormat(NdArray.F32_LE, (4096,); layout = NdArray.ROW_MAJOR),
        nothing, zeros(Float32, 4096),
    )
    @test_throws ArgumentError Session.encode_request(
        header, Runner.RunnerCommand(:parameter_ndarray, "graph", "reference", oversized_inline),
    )

    file_header = Codec.RequestHeader(controller, Int64(24), Int64(26), UInt32(14), Int64(1_000_000))
    legacy = Runner.RunnerCommand(
        :parameter, "graph", "reference", "F32_LE", UInt32[2, 3], "schema", "/legacy/path",
    )
    @test last(Runner.decode_request(Session.encode_request(file_header, legacy))).args == legacy.args
    @test_throws ArgumentError Codec.encode_request(
        file_header, SPA.Struct([ndarray_format(format; id = SPA.PARAM_FORMAT)]),
    )
end

function parameter_ndarray_fixture()
    controller = Codec.ControllerIdentity(UInt32(9), UInt64(0x8000000000000011), Int64(13))
    header = Codec.RequestHeader(controller, Int64(24), Int64(25), UInt32(17), Int64(5_000_000_000))
    format = NdArrayFormat(NdArray.F32_LE, (2, 3); layout = NdArray.COLUMN_MAJOR)
    values = Float32[-0.0, 1.25, -2.5, 0.125, 64.0, -64.0]
    command = Runner.RunnerCommand(
        :parameter_ndarray, "graph", "reference", Runner.ParameterNdArray(format, nothing, values),
    )
    request = Session.encode_request(header, command)
    reply_header = Codec.ReplyHeader(
        header.controller, header.endpoint_instance, header.token, header.operation, Int32(0),
    )
    details = Pod(SPA.Struct(Pod[Pod("graph"), Pod("reference"), Pod(nothing), Pod(false)]))
    result = SPA.Struct(Pod[Pod(SPA.Id(UInt32(Runner.Ready))), Pod(SPA.Id(UInt32(Runner.Submitted))), details])
    return (; request, completion = Codec.encode_completion(reply_header, result; endpoint = :lifecycle))
end

const FIXTURE_DIRECTORY = joinpath(@__DIR__, "data", "native-parameter-ndarray")

@testset "Native parameter ndarray golden request and submission" begin
    expected = parameter_ndarray_fixture()
    if ARGS == ["--write-golden"]
        write(joinpath(FIXTURE_DIRECTORY, "request.pod"), expected.request.data)
        write(joinpath(FIXTURE_DIRECTORY, "completion.pod"), expected.completion.data)
    end
    request = read(joinpath(FIXTURE_DIRECTORY, "request.pod"))
    completion = read(joinpath(FIXTURE_DIRECTORY, "completion.pod"))
    @test expected.request.data == request
    @test expected.completion.data == completion
    header, command = Runner.decode_request(request)
    parameter = command.args[3]
    @test parameter.schema === nothing
    @test reinterpret(UInt32, first(parameter.data)) == 0x80000000
    reply = Session.decode_completion(completion)
    @test header.operation == reply.header.operation == 17
    @test header.controller == reply.header.controller
    @test header.token == reply.header.token
    @test reply.result.outcome == Runner.Submitted
    @test !reply.result.details.active_adoption_observed
end

mutable struct ExpiringParameterCompletion
    instance::Int64
    pending::Any
    completion::Pod
end

function Parameter.Endpoint.complete!(endpoint::ExpiringParameterCompletion, ticket, completion)
    @test endpoint.pending === ticket
    reply = Parameter.Client.decode_completion(Parameter.PROFILE, completion)
    reply.header.result == 0 && error("native owner request deadline expired")
    endpoint.completion = completion
    endpoint.pending = nothing
    return nothing
end

@testset "Late parameter acknowledgement retains submission without losing the owner" begin
    fixture = parameter_ndarray_fixture()
    header, request = Runner.decode_request(fixture.request)
    original = header.controller
    command = Parameter.NdArrayParameter(request.args..., original)
    ticket = (; header, command)
    endpoint = ExpiringParameterCompletion(header.endpoint_instance, ticket, Pod(nothing))
    source = (; sequence = Int64(6), phase = Parameter.SUBMITTED)
    @test Parameter._completion!(endpoint, ticket, source, Int32(0), "") === nothing
    reply = Parameter.Client.decode_completion(Parameter.PROFILE, endpoint.completion)
    @test endpoint.pending === nothing
    @test reply.header.result == -Base.Libc.ETIMEDOUT
    @test reply.header.operation == header.operation && reply.header.token == header.token
    @test reply.sequence == 6 && reply.submitted && !reply.active_adoption_observed
end
