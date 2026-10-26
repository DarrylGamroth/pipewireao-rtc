# Optional CPU selector: requires the scientific packages and the native SDK.
using Test, PipeWireAORTC, PipeWireAO, FilterGraphAlgorithms, FilterGraphPipeWire, JuliaFilterGraph

const Loops = PipeWireAORTC.CorrectionLoops

function correction_graph()
    mktemp() do path, io
        write(io, """
        filter.graph = {
            nodes = [ {
                type = ndarray
                name = correction
                label = closed-loop-correction-f32
                config = { state_length = 2 hidden_mode_count = 1 }
            } ]
            links = []
            inputs = [ "correction:residual-error" "correction:constraint-feedback"
                       "correction:shape-to-hidden" "correction:hidden-to-shape" ]
            outputs = [ "correction:correction" "correction:controller-state" ]
        }
        """)
        flush(io)
        return JuliaFilterGraph.prepare_graph(path; algorithms=FilterGraphAlgorithms.algorithms())
    end
end

@testset "RTC Hsm observes actual graph property adoption" begin
    observer = Loops.Observer(["correction:closed"], Int64(17))
    node = FilterGraphPipeWire.PipeWireNode(correction_graph(); connect=false, property_observer=observer)
    sm = only(observer.loops)
    callbacks = node.filter.callbacks
    try
        @test Loops.check_ready(observer) === nothing
        @test Loops.state(sm) === :Closed
        callbacks.on_properties(node.filter, PipeWireAO.SPA.Props("correction:closed" => false))
        @test Loops.state(sm) === :Opening
        callbacks.on_get_properties(node.filter)
        @test Loops.state(sm) === :Opening
        @test_throws FilterGraphAlgorithms.PropertyUpdateBusy callbacks.on_properties(
            node.filter, PipeWireAO.SPA.Props("correction:closed" => true))
        @test Loops.state(sm) === :Opening
        @test FilterGraphPipeWire._adopt_pending_properties!(node.owner)
        # Processing adoption does not call Hsm; queued owner readback does.
        @test Loops.state(sm) === :Opening
        callbacks.on_get_properties(node.filter)
        @test Loops.state(sm) === :Open
        callbacks.on_properties(node.filter, PipeWireAO.SPA.Props("correction:closed" => true))
        @test Loops.state(sm) === :Closing
        @test FilterGraphPipeWire._adopt_pending_properties!(node.owner)
        # Accept an opposite write before the queued readback for Close.
        callbacks.on_properties(node.filter, PipeWireAO.SPA.Props("correction:closed" => false))
        @test Loops.state(sm) === :Opening
        @test FilterGraphPipeWire._adopt_pending_properties!(node.owner)
        callbacks.on_get_properties(node.filter)
        @test Loops.state(sm) === :Open
        @test sm.failure === nothing
        @test sm.requested_generation == sm.active_generation == 3
        callbacks.on_properties(node.filter, PipeWireAO.SPA.Props("correction:gain" => -0.2f0))
        @test Loops.state(sm) === :Open
        @test FilterGraphPipeWire._adopt_pending_properties!(node.owner)
        callbacks.on_get_properties(node.filter)
        @test Loops.state(sm) === :Open
        @test sm.failure === nothing
        @test sm.requested_generation == sm.active_generation == 4
    finally
        close(node)
    end
    for target in ("missing:closed", "correction:gain")
        observer = Loops.Observer([target], Int64(18))
        node = FilterGraphPipeWire.PipeWireNode(correction_graph(); connect=false, property_observer=observer)
        try
            @test_throws ArgumentError Loops.check_ready(observer)
            @test Loops.state(only(observer.loops)) === :Unknown
        finally
            close(node)
        end
    end
end
