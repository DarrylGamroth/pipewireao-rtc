#!/usr/bin/env julia
# RTC lifecycle wrapper: scientific code and owner-thread APIs stay with JFG.
include("native_owner_bootstrap.jl")
const Bootstrap = HILNativeOwnerBootstrap.Runtime
function run_native_graph(options, runtime)
    Bootstrap.preparation_check!(runtime)
    options.check && throw(ArgumentError("native graph owner cannot run --check"))
    options.session_run_control || throw(ArgumentError("native graph owner requires --session-run-control"))
    declarations = algorithm_declarations(options)
    Bootstrap.preparation_check!(runtime)
    workers = configure_threads(options)
    graph = prepare_service_graph(options; declarations, worker_thread_ids=workers)
    try
        Bootstrap.preparation_check!(runtime)
        common = (; name=options.name, remote=options.remote, rate=options.rate,
            connect=false, run_control=options.session_run_control)
        node = isnothing(options.capture_backend) ?
            FilterGraphPipeWire.PipeWireNode(graph; common..., boundary_layout=options.boundary_layout,
                fifo_inputs=options.fifo_inputs, feedback=options.feedback) :
            FilterGraphPipeWire.PipeWireNode(graph; common...)
        try
            if isnothing(options.capture_backend)
                FilterGraphPipeWire.prepare!(node;
                    execution=options.execution == "row-block" ? :row_block : :complete_frame,
                    required_outputs=options.warmup_outputs)
            end
            Bootstrap.preparation_check!(runtime)
            Bootstrap.prepared!(runtime)
            ticket = Bootstrap.take_connect!(runtime)
            Bootstrap.connecting!(runtime, ticket;
                ready=() -> FilterGraphPipeWire.node_id(node) !== nothing && PipeWireAO.isrunning(node) &&
                    FilterGraphPipeWire.node_state(node) in
                        (PipeWireAO.NDARRAY_FILTER_STATE_PAUSED, PipeWireAO.NDARRAY_FILTER_STATE_STREAMING),
                quit=() -> FilterGraphPipeWire.quit!(node))
            Bootstrap.check_connect!(runtime, ticket)
            FilterGraphPipeWire.connect!(node)
            Bootstrap.check_connect!(runtime, ticket)
            FilterGraphPipeWire.run!(node)
        catch error
            error isa InterruptException && Bootstrap.clean_cancel(runtime) && return nothing
            Bootstrap.fault!(runtime, error)
            rethrow()
        finally
            Bootstrap.finishing!(runtime)
            close(node)
        end
    finally
        close_execution(graph)
    end
    return nothing
end
function main(arguments=ARGS; owner_script=normpath(joinpath(@__DIR__, "..", "jfg", "deployment", "run_island.jl")))
    binding, graph_arguments = HILNativeOwnerBootstrap.graph_arguments(arguments)
    HILNativeOwnerBootstrap.with_owner(binding) do admitted
        admitted.owner_check()
        include(owner_script)
        admitted.owner_check()
        options = Base.invokelatest(parse_arguments, graph_arguments)
        Base.invokelatest(run_native_graph, options, admitted.bootstrap_runtime)
    end
end
abspath(PROGRAM_FILE) == (@__FILE__) && main()
