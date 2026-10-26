# Optional scientific integration selector. No native core or live session.
using Test, PipeWireAORTC
import FilterGraphAlgorithms as FGA
import JuliaFilterGraph as JFG

const Commands = PipeWireAORTC.RunnerCommands
const Codec = PipeWireAORTC.NativeRunnerCodec
const Envelope = PipeWireAORTC.NativeControlCodec

const LOOP_GRAPH = """
filter.graph = {
    nodes = [
        { type = ndarray name = correction label = closed-loop-integrator-f32
          config = { state_length = 2 }
          props = { gain = 0.25 pole = 1.0 anti-windup-gain = 1.0 closed = true } }
    ]
    inputs = [ "correction:residual-error" "correction:constraint-feedback" ]
    outputs = [ "correction:correction" "correction:controller-state" ]
}
"""

function loop_command(closed, token)
    command = Commands.parse(["property", "arbitrary-controller", "correction:closed",
        "bool", string(closed)])
    header = Envelope.RequestHeader(Envelope.ControllerIdentity(UInt32(1), UInt64(2), Int64(3)),
        Int64(4), Int64(token), Codec.operation_id(command), Int64(1_000_000))
    decoded_header, decoded = Codec.decode_request(Codec.encode_request(header, command))
    @test decoded_header.operation == UInt32(13) # existing property transaction
    @test decoded.args[1] == "arbitrary-controller"
    scalar = decoded.args[2]["correction:closed"]
    @test scalar.kind === :bool
    @test scalar.value === closed
    return decoded
end

function adopt_loop_command!(graph, command)
    # The existing owner stages validated scalar writes and adopts them between
    # frames. This selector checks that same decoded property against the
    # scientific owner; it does not claim native-daemon integration coverage.
    assignments = (name => scalar.value for (name, scalar) in command.args[2])
    return JFG.replace_properties!(graph, assignments...)
end

@testset "RTC scalar loop command holds correction without stopping processing" begin
    mktemp() do path, io
        write(io, LOOP_GRAPH)
        close(io)
        graph = JFG.prepare_graph(path; algorithms=FGA.algorithms())
        residual = Float32[2, -4]
        feedback = zeros(Float32, 2)
        inputs = (var"residual-error"=residual, var"constraint-feedback"=feedback)
        correction, state = zeros(Float32, 2), zeros(Float32, 2)
        outputs = (;correction, var"controller-state"=state)
        @test JFG.process!(outputs, graph, inputs) ==
            (correction=true, var"controller-state"=true)
        @test correction == Float32[0.5, -1]
        held_correction, held_state = copy(correction), copy(state)

        adopt_loop_command!(graph, loop_command(false, 1))
        residual .= 100
        feedback .= 0.125
        for _ in 1:8
            @test JFG.process!(outputs, graph, inputs) ==
                (correction=true, var"controller-state"=true)
            @test correction == held_correction
            @test state == held_state
        end
        @test FGA.property_values(only(graph.nodes).prepared.plan).closed === false

        adopt_loop_command!(graph, loop_command(true, 2))
        residual .= Float32[2, -4]
        feedback .= Float32[0.125, -0.25]
        @test JFG.process!(outputs, graph, inputs) ==
            (correction=true, var"controller-state"=true)
        @test correction == Float32[0.875, -1.75]
        @test state == Float32[0.375, -0.75]
        @test FGA.property_values(only(graph.nodes).prepared.plan).closed === true
    end
end
