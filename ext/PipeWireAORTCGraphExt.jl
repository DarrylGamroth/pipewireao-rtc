module PipeWireAORTCGraphExt

import PipeWireAORTC
import FilterGraphIsland
import FilterGraphPipeWire
import JuliaFilterGraph
import PipeWireAO
import FilterGraphAlgorithms

const Owner = PipeWireAORTC.GraphOwner
const Bootstrap = PipeWireAORTC.NativeOwnerBootstrapRuntime

include("analysis.jl")

function PipeWireAORTC.InstrumentConfiguration.controlled_actuators(declaration::NamedTuple,
        selection::AbstractDict, count::Int)
    IC = PipeWireAORTC.InstrumentConfiguration
    E = PipeWireAORTC.InstrumentExport
    D = PipeWireAORTC.DeploymentConfiguration
    prefix = get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao")
    source = D.relative_asset(declaration.directory,selection["graph"])
    bindings = D.relative_asset(declaration.directory,selection["bindings"])
    names = (Symbol(selection["active_to_full"]),Symbol(selection["pdm_to_vdm"]))
    entries = Owner.bindings(bindings,IC.bounded_yaml(bindings))
    selected = map(names) do name
        matches = filter(entry -> entry.port==name,entries)
        length(matches)==1 || throw(ArgumentError("controlled actuator selection names an absent FITS parameter $name"))
        entry = only(matches)
        D.relative_asset(declaration.directory,relpath(entry.source.path,declaration.directory))
        return entry
    end
    context = E.graph_context(IC.json_value(IC.physical_definition(declaration.instrument));
        dimensions=declaration.document["dimensions"],mirror_controls=declaration.controls["deformable_mirrors"],
        calibration=declaration.calibration)
    concrete = E.resolve_graph_configuration(D.decode(source,prefix),context)
    return mktempdir() do directory
        path = joinpath(directory,"graph.conf")
        PipeWireAORTC.ScienceExport.write_spa_config(path,concrete)
        options = FilterGraphIsland.parse_arguments(["--graph",path,"--check","--execution","complete-frame"])
        updates = Pair{Symbol,Array}[]
        graph = FilterGraphIsland.prepare_service_graph(options; initial_parameters=formats -> begin
            append!(updates,Owner.prepare_bindings(selected,formats))
            updates
        end)
        try
            values = Dict(updates)
            completion,inverse = map(name -> values[name],names)
            ndims(completion)==ndims(inverse)==2 || throw(DimensionMismatch("shape selection requires two matrix parameters"))
            eltype(completion)===eltype(inverse)===Float32 || throw(ArgumentError("shape selection requires Float32 projections"))
            size(inverse,2)==count || throw(DimensionMismatch("shape projection physical extent differs from mirror commands"))
            plan = FilterGraphAlgorithms.VdmShapeOffsetPlan(completion,inverse,zeros(Float32,count))
            return Tuple(plan.controlled_actuators)
        finally
            FilterGraphIsland.close_execution(graph)
        end
    end
end

function PipeWireAORTC.InstrumentExport.graph_port_contracts(path::AbstractString)
    options = FilterGraphIsland.parse_arguments([
        "--graph", String(path), "--check", "--execution", "complete-frame"])
    graph = FilterGraphIsland.prepare_service_graph(options)
    try
        return Dict(section => Dict(string(name) => PipeWireAORTC.InstrumentExport.port_contract(format)
            for (name, format) in pairs(formats(graph)))
            for (section, formats) in (("inputs", JuliaFilterGraph.input_formats),
                ("parameters", JuliaFilterGraph.parameter_formats),
                ("outputs", JuliaFilterGraph.output_formats)))
    finally
        FilterGraphIsland.close_execution(graph)
    end
end

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
