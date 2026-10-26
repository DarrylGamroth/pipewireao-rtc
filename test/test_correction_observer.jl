# Optional CPU selector: requires the scientific packages and the native SDK.
using Test, PipeWireAORTC, PipeWireAO, FilterGraphAlgorithms, FilterGraphPipeWire, JuliaFilterGraph

const Loops = PipeWireAORTC.CorrectionLoops

function observed_node(observer)
    return FilterGraphPipeWire.PipeWireNode(correction_graph(); connect=false,
        property_observer=observer, property_info=Loops.property_info(observer),
        property_getter=observer)
end

function status_value(props, suffix)
    name = Loops.STATUS_PREFIX * suffix
    return PipeWireAO.pod_value(only(last(pair) for pair in props.values if first(pair) == name))
end

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
    node = observed_node(observer)
    sm = only(observer.loops)
    callbacks = node.filter.callbacks
    try
        @test Loops.check_ready(observer) === nothing
        @test Loops.state(sm) === :Closed
        initial = callbacks.on_get_properties(node.filter)
        @test status_value(initial, "version") == Int32(1)
        @test status_value(initial, "owner-instance") == Int64(17)
        @test status_value(initial, "correction:closed.state") == "Closed"
        @test status_value(initial, "correction:closed.fault") == ""
        callbacks.on_properties(node.filter, PipeWireAO.SPA.Props("correction:closed" => false))
        @test Loops.state(sm) === :Opening
        pending = callbacks.on_get_properties(node.filter)
        @test status_value(pending, "correction:closed.requested") === false
        @test status_value(pending, "correction:closed.state") == "Opening"
        @test Loops.prop_value(Bool, pending, "correction:closed") === true
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
        @test_throws ArgumentError callbacks.on_properties(node.filter,
            PipeWireAO.SPA.Props(Loops.STATUS_PREFIX * "version" => Int32(2),
                "correction:gain" => -0.3f0))
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

@testset "RTC correction status expires before late adoption" begin
    now = Ref(UInt64(0))
    observer = Loops.Observer(["correction:closed"], Int64(19);
        timeout_ms=1, clock=() -> now[])
    node = observed_node(observer)
    callbacks = node.filter.callbacks
    try
        callbacks.on_properties(node.filter, PipeWireAO.SPA.Props("correction:closed" => false))
        now[] = UInt64(999_999)
        pending = callbacks.on_get_properties(node.filter)
        @test status_value(pending, "correction:closed.state") == "Opening"
        now[] += UInt64(1)
        expired = callbacks.on_get_properties(node.filter)
        @test status_value(expired, "correction:closed.state") == "Unknown"
        @test occursin("timeout", status_value(expired, "correction:closed.fault"))
        @test Loops.prop_value(Bool, expired, "correction:closed") === true
        @test FilterGraphPipeWire._adopt_pending_properties!(node.owner)
        late = callbacks.on_get_properties(node.filter)
        @test Loops.prop_value(Bool, late, "correction:closed") === false
        @test status_value(late, "correction:closed.state") == "Unknown"
        @test only(observer.loops).failure === :adoption_timeout
    finally
        close(node)
    end
end

@testset "Disabled graph observer cannot publish healthy correction status" begin
    observer = Loops.Observer(["correction:closed"], Int64(20))
    node = observed_node(observer)
    getter = node.filter.callbacks.on_get_properties
    try
        @test Loops.state(only(observer.loops)) === :Closed
        getter.observer.disabled[] = true
        props = getter(node.filter)
        @test Loops.prop_value(Bool, props, "correction:closed") === true
        @test status_value(props, "correction:closed.state") == "Unknown"
        @test only(observer.loops).failure === :observer_unavailable
    finally
        close(node)
    end
end
