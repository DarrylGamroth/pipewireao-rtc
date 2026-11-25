using Test, PipeWireAO, PipeWireAORTC
import Clocks

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
    rendered = PipeWireAORTC.RunnerCommands.render(reply)
    @test rendered["ok"]
    @test rendered["id"] == string(header.token)
    @test rendered["result"] == Dict(
        "outcome" => "submitted",
        "graph" => "graph",
        "parameter" => "reference",
        "active_adoption_observed" => false,
        "parameter_generations" => nothing,
    )
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

@testset "Native parameter requests fit the authenticated forward" begin
    media = PipeWireAORTC.MediaSession
    ingress = media.Ingress
    identity = media.Identity(3, 4, 5, 6)
    controller = Codec.ControllerIdentity(identity.global_id, identity.serial, Int64(identity.instance))
    session_header = Codec.RequestHeader(controller, Int64(1), Int64(1), UInt32(17), Int64(5_000_000_000))
    owner_header = Codec.RequestHeader(controller, Int64(2), Int64(1), UInt32(17), Int64(5_000_000_000))
    function native_gate()
        gate = ingress.Gate(1; clock = Clocks.CachedNanoClock(Int64(0)), owner_pid = 2)
        ingress.controllers!(gate, [ingress.Controller(identity, "test parameter controller")])
        ingress.state!(gate, Runner.Running)
        ingress.take_actions!(gate)
        return gate
    end

    vector = NdArrayFormat(NdArray.F32_LE, (3966,); layout = NdArray.ROW_MAJOR)
    matrix = NdArrayFormat(NdArray.F32_LE, (64, 64); layout = NdArray.ROW_MAJOR)
    near_limit = Runner.ParameterNdArray(vector, nothing, zeros(Float32, 3966))
    stream = Runner.ParameterNdArray(
        matrix, nothing, Runner.ParameterStream(UInt32(30), UInt64(31), UInt32(32), UInt64(33)),
    )
    for parameter in (near_limit, stream)
        command = Runner.RunnerCommand(:parameter_ndarray, "g", "p", parameter)
        wire = Session.encode_request(session_header, command)
        _, decoded = Runner.decode_request(wire)
        @test decoded.args[3].data == parameter.data
        gate = native_gate()
        ingress.receive!(gate, wire, Int64(0))
        dispatch = only(filter(action -> action isa ingress.DispatchRequest, ingress.take_actions!(gate)))
        @test dispatch.ticket === gate.pending
        @test dispatch.ticket.command.args[3].data == parameter.data
        forward = Parameter.NdArrayParameter(decoded.args..., controller)
        owner_wire = Parameter.Client.encode_request(Parameter.PROFILE, owner_header, forward)
        _, received = Parameter.Client.decode_request(Parameter.PROFILE, owner_wire)
        @test received.parameter.data == parameter.data
        @test received.controller == controller
        @test sizeof(owner_wire) <= 16 * 1024
        if parameter === near_limit
            @test sizeof(owner_wire) == 16 * 1024
        end
    end

    oversized = Runner.ParameterNdArray(
        NdArrayFormat(NdArray.F32_LE, (3967,); layout = NdArray.ROW_MAJOR),
        nothing, zeros(Float32, 3967),
    )
    command = Runner.RunnerCommand(:parameter_ndarray, "g", "p", oversized)
    @test_throws ArgumentError Session.encode_request(session_header, command)
    @test_throws ArgumentError Parameter.Client.encode_request(
        Parameter.PROFILE, owner_header, Parameter.NdArrayParameter(command.args..., controller),
    )

    # The common envelope can be written directly by a native client.
    native = Codec.encode_request(session_header, Runner._request_fields(command, command.args))
    @test sizeof(native) == 16_336
    @test_throws ArgumentError Runner.decode_request(native)
    gate = native_gate()
    ingress.receive!(gate, native, Int64(0))
    @test gate.pending === nothing
    @test gate.last_token == 0
    @test !any(action -> action isa ingress.DispatchRequest, ingress.take_actions!(gate))
    rejection, _ = Codec.decode_rejection(gate.rejection; endpoint = :lifecycle)
    @test rejection.result == -Base.Libc.EINVAL
    @test rejection.controller === nothing
end
