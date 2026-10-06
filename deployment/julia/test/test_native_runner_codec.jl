module NativeRunnerCodecTests

using Test
using PipeWireAO
using PipeWireAODeployment

# The package include is owned by integration; this standalone test can run now.
if !isdefined(PipeWireAODeployment, :NativeRunnerCodec)
    Base.include(PipeWireAODeployment,
        joinpath(dirname(@__DIR__), "src", "native_runner_codec.jl"))
end

const Runner = PipeWireAODeployment.NativeRunnerCodec
const Envelope = PipeWireAODeployment.NativeControlCodec
const SPA = PipeWireAO.SPA
const Pod = PipeWireAO.Pod

const identity = Envelope.ControllerIdentity(UInt32(7), typemax(UInt64), Int64(9))
request_header(op; token=Int64(op)) =
    Envelope.RequestHeader(identity, Int64(42), token, UInt32(op), Int64(1_000_000_000))
reply_header(op; result=Int32(0)) =
    Envelope.ReplyHeader(identity, Int64(42), Int64(op), UInt32(op), result)
ps(x...) = SPA.Struct(Pod[x...])
p(x) = Pod(x)
id(x) = p(SPA.Id(UInt32(x)))
function reply(op, outcome, details; lifecycle=Runner.Ready)
    Envelope.encode_completion(reply_header(op), ps(id(lifecycle), id(outcome), p(details)); endpoint=:lifecycle)
end


@testset "native runner profile" begin
    minus_zero = Runner.RunnerScalar(:float, reinterpret(UInt32, -0.0f0))
    props = Dict{String,Runner.RunnerScalar}("node.gain" => minus_zero)
    commands = [
        Runner.RunnerCommand(:quit), Runner.RunnerCommand(:groups),
        Runner.RunnerCommand(:status), Runner.RunnerCommand(:properties, "graph"),
        Runner.RunnerCommand(:property_generation, "graph", "node"),
        Runner.RunnerCommand(:parameter_generation, "graph", "node"),
        Runner.RunnerCommand(:stop_group, "g"), Runner.RunnerCommand(:start_group, "g"),
        Runner.RunnerCommand(:session_stop), Runner.RunnerCommand(:session_start),
        Runner.RunnerCommand(:source_ended), Runner.RunnerCommand(:reset),
        Runner.RunnerCommand(:properties_set, "graph", props),
        Runner.RunnerCommand(:parameter, "graph", "node.param", "F32_LE", UInt32[2, 3], "", "/tmp/value"),
    ]
    @testset "all 14 exact request operations" begin
        for (op, command) in enumerate(commands)
            @test Runner.operation_id(command) == op
            bytes = Runner.encode_request(request_header(op), command)
            header, payload = Envelope.decode_request(bytes)
            @test header.operation == op
            @test length(payload.values) == (op in (1, 2, 3, 9, 10, 11, 12) ? 0 :
                op in (4, 7, 8) ? 1 : op in (5, 6, 13) ? 2 : 6)
            @test sizeof(bytes) <= 16 * 1024
            base = sizeof(Envelope.encode_request(request_header(op), SPA.Struct()))
            @test Runner._preflight_request(command, base) == sizeof(bytes)
        end
        @test_throws ArgumentError Runner.encode_request(request_header(2), commands[1])
        @test_throws ArgumentError Runner.encode_request(request_header(4), Runner.RunnerCommand(:properties))
        @test_throws ArgumentError Runner.encode_request(request_header(13),
            Runner.RunnerCommand(:properties_set, "graph", Dict{String,Runner.RunnerScalar}()))
        @test_throws ArgumentError Runner.encode_request(request_header(13),
            Runner.RunnerCommand(:properties_set, "graph", Dict("p" =>
                Runner.RunnerScalar(:float, reinterpret(UInt32, Float32(NaN))))))
        oversized = Dict{String,Runner.RunnerScalar}(
            "node.$i" => Runner.RunnerScalar(:string, repeat("a", 1_000)) for i in 1:42)
        @test_throws ArgumentError Runner.encode_request(request_header(13),
            Runner.RunnerCommand(:properties_set, "graph", oversized))
        @test_throws ArgumentError Runner.encode_request(request_header(14),
            Runner.RunnerCommand(:parameter, "g", "p", "F32_LE", UInt32[typemax(UInt32)], "", "/tmp/p"))
    end

    @testset "all 14 exact completion operations" begin
        big = reinterpret(Int64, typemax(UInt64))
        nan_bits = UInt32(0x7fc00011)
        rows = ps(p(ps(p("g"), id(2))))
        sink_rows = ps(p(ps(p("sink"), p(big))))
        property_rows = ps(p(ps(p("node.gain"), p(reinterpret(Float32, nan_bits)))))
        generations = ps(p(ps(p("node"), p(Int64(5)), p(Int64(5)))))
        cases = [
            (Runner.Accepted, ps(p(true)), Runner.Ready),
            (Runner.Observed, ps(p(rows)), Runner.Ready),
            (Runner.Observed, ps(p(true), p(big), p(big), p(big), p(sink_rows)), Runner.Running),
            (Runner.Observed, ps(p("graph"), p(property_rows)), Runner.Ready),
            (Runner.Observed, ps(p("graph"), p("node"), p(Int64(4)), p(nothing)), Runner.Ready),
            (Runner.Observed, ps(p("graph"), p("node"), p(Int64(4)), p(Int64(3))), Runner.Ready),
            (Runner.Requested, ps(p("g"), id(1), p(nothing)), Runner.Ready),
            (Runner.Requested, ps(p("g"), id(2), id(2)), Runner.Running),
            (Runner.Completed, ps(id(3)), Runner.Ready),
            (Runner.Completed, ps(id(4)), Runner.Running),
            (Runner.Completed, ps(id(3)), Runner.Ready),
            (Runner.Completed, ps(id(3)), Runner.Ready),
            (Runner.Active, ps(p("graph"), p(generations), p(true)), Runner.Running),
            (Runner.Submitted, ps(p("graph"), p("node.param"), p(ps(p(Int64(3)), p(Int64(2)))), p(false)), Runner.Running),
        ]
        for (op, (outcome, details, lifecycle)) in enumerate(cases)
            completion = Runner.decode_completion(reply(op, outcome, details; lifecycle))
            @test completion.header.operation == op
            @test completion.lifecycle == lifecycle
            @test completion.result.outcome == outcome
            @test completion.error === nothing
        end
        status = Runner.decode_completion(reply(3, Runner.Observed, cases[3][2]; lifecycle=Runner.Running))
        @test status.result.details.owned_nodes == typemax(UInt64)
        @test status.result.details.discarded_by_sink["sink"] == typemax(UInt64)
        properties = Runner.decode_completion(reply(4, Runner.Observed, cases[4][2]))
        @test properties.result.details.properties["node.gain"].value == nan_bits
        long_snapshot = ps(p("graph"), p(ps(p(ps(p("node.text"), p(repeat("x", 20_000)))))))
        observed_long = Runner.decode_completion(reply(4, Runner.Observed, long_snapshot))
        @test length(observed_long.result.details.properties["node.text"].value) == 20_000
        @test Runner.decode_completion(reply(5, Runner.Observed, cases[5][2])).result.details.active === nothing
    end

    @testset "errors and exact schema rejection" begin
        negative = Envelope.ReplyHeader(identity, Int64(42), Int64(3), UInt32(3), Int32(-5))
        error_payload = ps(p("runner"), p("failed"), id(Runner.Fault))
        failure = Runner.decode_completion(Envelope.encode_completion(negative, error_payload))
        @test failure.result === nothing && failure.error.message == "failed"
        reject = Runner.decode_rejection(Envelope.encode_rejection(negative, error_payload))
        @test reject.error.field == "runner"
        sentinel = Envelope.ReplyHeader(Int64(42), Int32(-22))
        @test Runner.decode_rejection(Envelope.encode_rejection(sentinel, error_payload)).header.controller === nothing
        @test_throws ArgumentError Runner.decode_completion(Envelope.encode_completion(
            Envelope.ReplyHeader(Int64(42), Int32(0)), ps()))
        @test_throws ArgumentError Runner.decode_completion(reply(1, Runner.Submitted, ps(p(true))))
        @test_throws ArgumentError Runner.decode_completion(reply(10, Runner.Completed, ps(id(3))))
        @test_throws ArgumentError Runner.decode_completion(reply(14, Runner.Submitted,
            ps(p("g"), p("p"), p(nothing), p(true))))
        duplicate_rows = ps(p(ps(p("g"), id(1))), p(ps(p("g"), id(2))))
        @test_throws ArgumentError Runner.decode_completion(reply(2, Runner.Observed, ps(p(duplicate_rows))))
        bad_generation = ps(p(ps(p("n"), p(nothing), p(Int64(1)))))
        @test_throws ArgumentError Runner.decode_completion(reply(13, Runner.Submitted,
            ps(p("g"), p(bad_generation), p(false))))
    end
end

end # module NativeRunnerCodecTests
