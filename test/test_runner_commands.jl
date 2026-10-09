module RunnerCommandsTests

using Test
using PipeWireAODeployment

if !isdefined(PipeWireAODeployment, :RunnerCommands)
    Base.include(PipeWireAODeployment,
        joinpath(dirname(@__DIR__), "src", "runner_commands.jl"))
end

const RC = PipeWireAODeployment.RunnerCommands
const Codec = PipeWireAODeployment.NativeRunnerCodec
const Envelope = PipeWireAODeployment.NativeControlCodec
const SPA = PipeWireAODeployment.NativeRunnerCodec.PipeWireAO.SPA
const Pod = PipeWireAODeployment.NativeRunnerCodec.PipeWireAO.Pod
p(x) = Pod(x)
ps(x...) = SPA.Struct(Pod[x...])
id(x) = p(SPA.Id(UInt32(x)))

const controller = Envelope.ControllerIdentity(UInt32(9), UInt64(10), Int64(11))
function completion(operation, outcome, details; lifecycle=Codec.Ready, token=Int64(operation))
    header = Envelope.ReplyHeader(controller, Int64(77), token, UInt32(operation), Int32(0))
    payload = ps(id(lifecycle), id(outcome), p(details))
    return Codec.decode_completion(Envelope.encode_completion(header, payload))
end

@testset "legacy command parser maps to typed codec commands" begin
    commands = [
        ("quit", 1), ("exit", 1), ("groups", 2), ("status", 3),
        ("properties g", 4), ("property-generation g n", 5),
        ("parameter-generation g n", 6), ("stop group", 7),
        ("start group", 8), ("session-stop", 9), ("session-start", 10),
        ("source-ended", 11), ("reset", 12),
        ("property g n:v bool true", 13),
        ("properties-set g n:i int -3 n:f float 0.5", 13),
        ("parameter g n:p F32_LE 2x3 schema /tmp/value", 14),
    ]
    for (line, operation) in commands
        command = RC.parse(String.(split(line)))
        @test Codec.operation_id(command) == operation
        request = Envelope.RequestHeader(controller, Int64(77), Int64(operation),
            UInt32(operation), Int64(1_000_000))
        encoded = Codec.encode_request(request, command)
        decoded_header, _ = Envelope.decode_request(encoded)
        @test decoded_header.operation == operation
    end
    @test RC.parse(["properties-set", "g", "a", "long", "1", "b", "id", "4294967295"]).args[2]["b"].value == typemax(UInt32)
    scalar_fields = [
        ("bool", "true", :bool, true), ("bool", "false", :bool, false),
        ("int", "-2147483648", :int, typemin(Int32)),
        ("long", "9223372036854775807", :long, typemax(Int64)),
        ("float", "-0.0", :float, reinterpret(UInt32, -0.0f0)),
        ("double", "0.25", :double, reinterpret(UInt64, 0.25)),
        ("id", "4294967295", :id, typemax(UInt32)),
        ("string", "text", :string, "text"),
    ]
    for (value_type, value, kind, expected) in scalar_fields
        command = RC.parse(["property", "g", "n:value", value_type, value])
        scalar = command.args[2]["n:value"]
        @test scalar.kind === kind
        @test scalar.value == expected
    end
    @test_throws ArgumentError RC.parse(["properties-set", "g", "n", "int", "1", "n", "int", "2"])
    @test_throws ArgumentError RC.parse(["properties-set", "g", "n", "float", "NaN"])
    @test_throws ArgumentError RC.parse(["properties-set", "g", "n", "double", "Inf"])
    @test_throws ArgumentError RC.parse(["property", "g", "n", "bool", "TRUE"])
    @test_throws ArgumentError RC.parse(["parameter", "g", "p", "F32_LE", "0x2", "s", "/tmp/x"])
    @test_throws ArgumentError RC.parse(["parameter", "g", "p", "F32_LE", "4294967295x4294967295", "s", "/tmp/x"])
    @test_throws ArgumentError RC.parse(vcat(["status"], fill("unused", 128)))
    @test_throws ArgumentError RC.parse(["status\0"])
    @test_throws ArgumentError RC.parse(["not-a-command"])
end

@testset "typed completion rendering preserves legacy result fields" begin
    group_rows = ps(p(ps(p("a"), id(1))), p(ps(p("b"), id(2))))
    sink_rows = ps(p(ps(p("sink"), p(Int64(5)))))
    property_rows = ps(p(ps(p("n:gain"), p(Float32(0.5f0)))))
    generation_rows = ps(p(ps(p("n"), p(Int64(2)), p(Int64(1)))))
    cases = [
        (1, Codec.Accepted, ps(p(true)), Codec.Ready, Dict("outcome"=>"accepted", "message"=>"shutdown requested", "shutdown"=>true)),
        (2, Codec.Observed, ps(p(group_rows)), Codec.Ready,
            Dict("outcome"=>"observed", "groups"=>Dict("a"=>"stopped", "b"=>"running"))),
        (3, Codec.Observed, ps(p(true), p(Int64(2)), p(Int64(3)), p(Int64(4)), p(sink_rows)), Codec.Running,
            Dict("outcome"=>"observed", "lifecycle_state"=>"Running", "running"=>true, "owned_nodes"=>UInt64(2), "owned_links"=>UInt64(3), "discarded_buffers"=>UInt64(4), "discarded_by_sink"=>Dict("sink"=>UInt64(5)))),
        (4, Codec.Observed, ps(p("g"), p(property_rows)), Codec.Ready,
            Dict("outcome"=>"observed", "graph"=>"g", "properties"=>Dict("n:gain"=>Dict("type"=>"float", "bits"=>reinterpret(UInt32, 0.5f0))))),
        (5, Codec.Observed, ps(p("g"), p("n"), p(Int64(7)), p(nothing)), Codec.Ready,
            Dict("outcome"=>"observed", "graph"=>"g", "node"=>"n", "requested"=>7, "active"=>nothing)),
        (6, Codec.Observed, ps(p("g"), p("n"), p(Int64(7)), p(Int64(7))), Codec.Ready,
            Dict("outcome"=>"observed", "graph"=>"g", "node"=>"n", "requested"=>7, "active"=>7)),
        (7, Codec.Requested, ps(p("g"), id(1), p(nothing)), Codec.Ready,
            Dict("outcome"=>"requested", "group"=>"g", "requested"=>"stopped", "observed"=>nothing)),
        (8, Codec.Requested, ps(p("g"), id(2), id(2)), Codec.Running,
            Dict("outcome"=>"requested", "group"=>"g", "requested"=>"running", "observed"=>"running")),
        (9, Codec.Completed, ps(id(3)), Codec.Ready, Dict("outcome"=>"completed", "session_state"=>"READY")),
        (10, Codec.Completed, ps(id(4)), Codec.Running, Dict("outcome"=>"completed", "session_state"=>"RUNNING")),
        (11, Codec.Completed, ps(id(3)), Codec.Ready, Dict("outcome"=>"completed", "session_state"=>"Ready")),
        (12, Codec.Completed, ps(id(3)), Codec.Ready, Dict("outcome"=>"completed", "session_state"=>"Ready")),
        (13, Codec.Submitted, ps(p("g"), p(generation_rows), p(false)), Codec.Ready,
            Dict("outcome"=>"submitted", "graph"=>"g", "active_adoption_observed"=>false,
                "property_generations"=>[Dict("node"=>"n", "requested"=>2, "active"=>1)])),
        (14, Codec.Submitted, ps(p("g"), p("n:p"), p(ps(p(Int64(3)), p(Int64(2)))), p(false)), Codec.Running,
            Dict("outcome"=>"submitted", "graph"=>"g", "parameter"=>"n:p", "active_adoption_observed"=>false,
                "parameter_generations"=>Dict("requested"=>3, "active"=>2))),
    ]
    for (op, outcome, fields, lifecycle, expected) in cases
        reply = completion(op, outcome, fields; lifecycle)
        rendered = RC.render(reply; request_id="operator-id")
        @test rendered["version"] == 1
        @test rendered["id"] == "operator-id"
        @test rendered["session_id"] == "native-runner-instance:77"
        @test rendered["state"] == string(lifecycle)
        @test rendered["ok"] && rendered["error"] === nothing
        @test rendered["result"] == expected
    end

    identity = Envelope.ReplyHeader(controller, Int64(77), Int64(3), UInt32(3), Int32(-7))
    failed = Codec.decode_completion(Envelope.encode_completion(identity,
        ps(p("runner.status"), p("owner failed"), id(Codec.Fault))))
    failed_render = RC.render(failed; request_id="failed-id")
    @test failed_render == Dict("version"=>1, "id"=>"failed-id",
        "session_id"=>"native-runner-instance:77", "state"=>"Fault", "result"=>nothing,
        "ok"=>false, "error"=>Dict("field"=>"runner.status", "message"=>"owner failed"))
    rejected = Codec.decode_rejection(Envelope.encode_rejection(identity,
        ps(p("control.busy"), p("runner already has a pending request"), id(Codec.Running))))
    rejected_render = RC.render(rejected; request_id="rejected-id")
    @test rejected_render == Dict("version"=>1, "id"=>"rejected-id",
        "session_id"=>"native-runner-instance:77", "state"=>"Running", "result"=>nothing,
        "ok"=>false, "error"=>Dict("field"=>"control.busy", "message"=>"runner already has a pending request"))
end

end # module RunnerCommandsTests
