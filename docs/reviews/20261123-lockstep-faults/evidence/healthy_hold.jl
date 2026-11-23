# Run in the HIL candidate's Julia 1.13 test environment. Use only a private core.
using AdaptiveOpticsSimPipeWireHIL, AdaptiveOpticsSim.AlgorithmGraphs, PipeWireAO, Test
using AdaptiveOpticsSim.AlgorithmGraphs: graph_port_contract
import PipeWireAO_jll

const fixtures = joinpath(pkgdir(AdaptiveOpticsSimPipeWireHIL), "test")
# The released fixture files mix top-level tests and definitions. Load only
# the declarations needed by the actual private-core three-output producer.
function include_declarations(name, first_marker, last_marker)
    path = joinpath(fixtures, name)
    src = read(path, String)
    first_byte = first(something(findfirst(first_marker, src)))
    last_byte = first(something(findnext(last_marker, src, first_byte)))
    include_string(Main, src[first_byte:prevind(src, last_byte)], path)
end
include_declarations("live_private_core.jl", "struct LiveTransportTestDeclaration",
    "include(\"live_exchange_private_core.jl\")")
include_declarations("multi_command.jl", "struct MultiCommandTestDeclaration",
    "function outstanding_multi_command")
include(joinpath(fixtures, "private_core_helpers.jl"))
include(joinpath(fixtures, "live_multi_command_private_core.jl"))

function trial(remote, hold_on_complete)
    boundary = multi_command_boundary()
    prepared = prepare_pipewire_hil(boundary, multi_command_configuration(; remote))
    native = nothing
    try
        producer = LiveMultiCommandProducer()
        native = _prepare_live_multi_producer(prepared, producer)
        start!(prepared)
        initial = deepcopy(boundary.command_input)
        receipts = Ref((UInt64(0), UInt64(0), UInt64(0)))
        function hold_requested()
            receipts[] = map(s -> s.command_ready[], values(prepared.state))
            return hold_on_complete && all(==(UInt64(1)), receipts[])
        end
        result = exchange_frame!(prepared; hold_requested)
        cursor = hil_boundary_status(boundary)
        println("hold_on_complete=", hold_on_complete, " receipts_at_decision=", receipts[],
            " exchange_result=", result, " exposure=", cursor.frame_sequence,
            " active_command=", cursor.active_command_sequence, " command=", boundary.command_input)
        @test receipts[] == (1, 1, 1)
        @test cursor.frame_sequence == 1
        @test !cursor.command_response_required
        if hold_on_complete
            @test isnothing(result)
            @test cursor.active_command_sequence == 0
            @test boundary.command_input == initial
        else
            @test result == 1
            @test cursor.active_command_sequence == 1
            @test boundary.command_input != initial
        end
    finally
        if native !== nothing
            with_thread_loop_lock(prepared.loop) do _
                foreach(close, reverse(native.links))
                close(native.producer)
                close(native.registry)
            end
        end
        close(prepared)
    end
end

@testset "healthy complete response at Hold decision" begin
    _with_private_core() do remote
        trial(remote, false)
        trial(remote, true)
    end
end
