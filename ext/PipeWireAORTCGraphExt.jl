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
include("correction_supervision.jl")

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

function PipeWireAORTC.InstrumentExport.validate_feedback(application, graph_path, binding_path, receiver_path)
    graphfile=joinpath(application,graph_path)
    entries=Owner.bindings(joinpath(application,binding_path))
    options=FilterGraphIsland.parse_arguments(["--graph",graphfile,"--check","--execution","complete-frame"])
    graph=FilterGraphIsland.prepare_service_graph(options;
        initial_parameters=formats->Owner.prepare_bindings(entries,formats))
    try
        path=joinpath(application,receiver_path)
        PipeWireAORTC.PhysicalOffsets.prepare(path,graph)
        PipeWireAORTC.PhysicalOffsets.frame_observer(path,nothing,JuliaFilterGraph.output_formats(graph))
    finally
        FilterGraphIsland.close_execution(graph)
    end
    return nothing
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
    correction_properties = options.correction_properties
    !isempty(correction_properties) && !isnothing(options.capture_backend) &&
        throw(ArgumentError("captured graph owners do not support runtime correction properties"))
    observer = isempty(correction_properties) ? nothing :
        PipeWireAORTC.CorrectionLoops.Observer(correction_properties, runtime.transport.endpoint.instance;
            timeout_ms=options.correction_timeout_ms)
    supervision = prepare_supervision(options, runtime.transport.endpoint.instance, graph)
    observation = correction_observation(observer, supervision)
    offsets_path = get(options,:physical_offsets,nothing)
    offsets_path === nothing || (options.capture_backend === nothing && options.execution == "complete-frame" &&
        Threads.nthreads(:default)>=3) || throw(ArgumentError("physical offsets require complete-frame CPU execution and three default threads"))
    offset_receiver = offsets_path === nothing ? nothing : PipeWireAORTC.PhysicalOffsets.prepare(offsets_path,graph)
    offset_clock = offsets_path === nothing ? nothing : PipeWireAORTC.PhysicalOffsets.frame_observer(
        offsets_path,get(observation,:frame_observer,nothing),JuliaFilterGraph.output_formats(graph))
    offsets_path === nothing || (observation=merge(observation,(;frame_observer=offset_clock)))
    recovery = isempty(options.recovery_nodes) ? (;) :
        (; recovery=(controller=Symbol(first(split(only(correction_properties), ':'))),
            participants=Tuple(Symbol.(options.recovery_nodes)),
            reference_timeout_ms=options.correction_timeout_ms))
    common = (; recovery..., name=options.name, remote=options.remote, rate=options.rate,
        connect=false, run_control=options.session_run_control,
        acquisition_version=options.acquisition_version, channel_units=options.channel_units)
    node = isnothing(options.capture_backend) ?
        FilterGraphPipeWire.PipeWireNode(graph; common..., observation..., boundary_layout=options.boundary_layout,
            fifo_inputs=options.fifo_inputs, feedback=options.feedback) :
        FilterGraphPipeWire.PipeWireNode(graph; common...)
    try
        isnothing(observer) || PipeWireAORTC.CorrectionLoops.check_ready(observer)
        isnothing(observer) || PipeWireAORTC.CorrectionLoops.attach_timers!(
            observer, runtime.transport.loop, () -> PipeWireAO.notify_properties!(node.filter))
        if isnothing(options.capture_backend)
            warmup = get(options, :chopped_warmup, nothing)
            samples = warmup === nothing ? nothing : chopped_warmup_samples(graph, options, warmup)
            FilterGraphPipeWire.prepare!(node;
                execution=options.execution == "row-block" ? :row_block : :complete_frame,
                required_outputs=options.warmup_outputs, samples)
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
        if offsets_path === nothing
            FilterGraphPipeWire.run!(node)
        else
            PipeWireAORTC.PhysicalOffsets.with_receiver(offset_receiver;node,remote=options.remote,frame_clock=offset_clock) do
                FilterGraphPipeWire.run!(node)
            end
        end
    catch error
        error isa InterruptException && Bootstrap.clean_cancel(runtime) && return nothing
        Bootstrap.fault!(runtime, error)
        rethrow()
    finally
        try
            Bootstrap.finishing!(runtime)
        finally
            try
                isnothing(observer) || close(observer)
            finally
                close(node)
            end
        end
    end
    return nothing
end

function chopped_warmup_samples(graph, options, warmup)
    options.acquisition_version == 3 && options.execution == "complete-frame" &&
        options.feedback === nothing && options.capture_backend === nothing ||
        throw(ArgumentError("chopped warmup requires ordinary complete-frame Acquisition Version 3"))
    formats = JuliaFilterGraph.input_formats(graph)
    keys(formats) == (warmup.input,) || throw(ArgumentError("chopped warmup requires its sole image input"))
    format = getproperty(formats, warmup.input)
    format.element_type === Float32 && length(format.shape) == 2 ||
        throw(ArgumentError("chopped warmup requires a Float32 image"))
    identity = sequence -> FilterGraphAlgorithms.SampleAcquisitionIdentity(
        ntuple(_ -> UInt8(0xa5), 16), UInt64(1), UInt64(sequence))
    return ntuple(3) do index
        fringed = isodd(index)
        metadata = FilterGraphAlgorithms.SampleMetadata(index; terminal=true,acquisition_version=3,
            trigger_high=fringed == warmup.trigger_high_is_fringed,
            chopped_image_kind=fringed ? FilterGraphAlgorithms.ChoppedImageFringed : FilterGraphAlgorithms.ChoppedImageUnfringed,
            acquisition_identity=identity(index), exposure_duration_nanoseconds=warmup.exposure_duration_ns)
        (; inputs=NamedTuple{(warmup.input,)}((ones(Float32, format.shape),)),
            metadata=NamedTuple{(warmup.input,)}((metadata,)),
            expected=index == 1 ? FilterGraphAlgorithms.SccPixelResidualIncompletePair : nothing)
    end
end

end
