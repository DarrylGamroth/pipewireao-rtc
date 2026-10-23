module PipeWireAORTCGraphExt

import PipeWireAORTC
import FilterGraphIsland
import FilterGraphPipeWire
import JuliaFilterGraph
import PipeWireAO

const Owner = PipeWireAORTC.GraphOwner
const Bootstrap = PipeWireAORTC.NativeOwnerBootstrapRuntime

include("analysis.jl")

function Owner.read_bindings(graph_path::AbstractString, binding_path::AbstractString)
    options = FilterGraphIsland.parse_arguments([
        "--graph", String(graph_path), "--check", "--execution", "complete-frame"])
    entries = Owner.bindings(binding_path)
    updates = Pair{Symbol,Array}[]
    graph = FilterGraphIsland.prepare_service_graph(options;
        initial_parameters=formats -> begin
            append!(updates, Owner.prepare_bindings(entries, formats))
            updates
        end)
    try
        return Dict(updates)
    finally
        FilterGraphIsland.close_execution(graph)
    end
end

function Owner.run_owner(island::Module, options, runtime, entries)
    Bootstrap.preparation_check!(runtime)
    options.check && throw(ArgumentError("native graph owner cannot run --check"))
    options.session_run_control || throw(ArgumentError("native graph owner requires --session-run-control"))
    raw_ports = Set(parameter.port for parameter in options.parameters)
    any(entry -> entry.port in raw_ports, entries) &&
        throw(ArgumentError("FITS parameter overlaps a legacy raw startup parameter"))
    declarations = island.algorithm_declarations(options)
    Bootstrap.preparation_check!(runtime)
    workers = island.configure_threads(options)
    initial_parameters = formats -> Owner.prepare_bindings(entries, formats;
        check=() -> Bootstrap.preparation_check!(runtime))
    graph = island.prepare_service_graph(options; declarations,
        worker_thread_ids=workers, initial_parameters)
    try
        # Optional provider methods loaded by declarations must be visible here.
        Base.invokelatest(run_prepared, options, runtime, graph)
    finally
        island.close_execution(graph)
    end
    return nothing
end

function run_prepared(options, runtime, graph)
    Bootstrap.preparation_check!(runtime)
    common = (; name=options.name, remote=options.remote, rate=options.rate,
        connect=false, run_control=options.session_run_control,
        acquisition_version=options.acquisition_version)
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
    return nothing
end

end
