module PipeWireAORTCGraphExt

import PipeWireAORTC
import FilterGraphPipeWire
import FilterGraphs
import PipeWireAO
import FilterGraphAlgorithms
import ThreadPinning
import Clocks

const Owner = PipeWireAORTC.GraphOwner
const Bootstrap = PipeWireAORTC.OwnerBootstrapRuntime

include("analysis.jl")
include("correction_supervision.jl")

function PipeWireAORTC.InstrumentConfiguration.controlled_actuators(
    declaration::NamedTuple, selection::AbstractDict, count::Int
)
    IC = PipeWireAORTC.InstrumentConfiguration
    E = PipeWireAORTC.InstrumentExport
    D = PipeWireAORTC.DeploymentConfiguration
    prefix = get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
    source = D.relative_asset(declaration.directory, selection["graph"])
    bindings = D.relative_asset(declaration.directory, selection["bindings"])
    names = (Symbol(selection["active_to_full"]), Symbol(selection["pdm_to_vdm"]))
    entries = Owner.bindings(bindings, IC.bounded_yaml(bindings))
    selected = map(names) do name
        matches = filter(entry -> entry.port == name, entries)
        length(matches) == 1 || throw(
            ArgumentError(
                "controlled actuator selection names an absent FITS parameter $name"
            ),
        )
        entry = only(matches)
        D.relative_asset(
            declaration.directory, relpath(entry.source.path, declaration.directory)
        )
        return entry
    end
    context = E.graph_context(
        IC.json_value(IC.physical_definition(declaration.instrument));
        dimensions = declaration.document["dimensions"],
        mirror_controls = declaration.controls["deformable_mirrors"],
        calibration = declaration.calibration,
    )
    concrete = E.resolve_graph_configuration(D.decode(source, prefix), context)
    formats = shape_parameter_formats(concrete, names, count)
    completion, inverse = last.(Owner.prepare_bindings(selected, formats))
    plan = FilterGraphAlgorithms.VdmShapeOffsetPlan(
        completion, inverse, zeros(Float32, count)
    )
    return Tuple(plan.controlled_actuators)
end

function shape_parameter_formats(document, names, count)
    graph = document["filter.graph"]
    endpoints = map(names) do name
        entry = only(filter(input -> input isa AbstractDict &&
            get(input, "name", nothing) == String(name), graph["inputs"]))
        return FilterGraphs.Endpoint(entry["endpoint"])
    end
    completion, inverse = endpoints
    completion.node === inverse.node &&
        completion.port === Symbol("active-to-full") &&
        inverse.port === Symbol("pdm-to-vdm") ||
        throw(ArgumentError("shape projections must bind the two Parameter Ports of one VDM shape node"))
    node = only(filter(node -> get(node, "name", nothing) == String(completion.node), graph["nodes"]))
    node["label"] == "vdm-shape-offset-f32" ||
        throw(ArgumentError("shape projections require a vdm-shape-offset-f32 node"))
    config = node["config"]
    active, full, physical = (config[key] for key in
        ("active_vdm_count", "full_vdm_count", "physical_actuator_count"))
    all(n -> n isa Integer && !(n isa Bool) && n > 0, (active, full, physical)) &&
        active <= full && physical == count ||
        throw(ArgumentError("shape projection dimensions differ from the mirror command contract"))
    return NamedTuple{names}((
        (; element_type=Float32, shape=(full, active)),
        (; element_type=Float32, shape=(full, physical)),
    ))
end

function Owner.metadata_profiles(graph; feedback = nothing)
    inputs = keys(FilterGraphs.input_formats(graph))
    outputs = keys(FilterGraphs.output_formats(graph))
    sources = NamedTuple{outputs}(FilterGraphs.output_metadata_source_inputs(graph))
    public_inputs = feedback === nothing ? inputs : filter(!=(first(feedback)), inputs)
    public_outputs = feedback === nothing ? outputs : filter(!=(last(feedback)), outputs)
    required = FilterGraphPipeWire.required_input_metadata(graph)
    return (;
        input_metadata = PipeWireAORTC.Common.telemetry_metadata_ports(
            public_inputs; required
        ),
        output_metadata = PipeWireAORTC.Common.telemetry_metadata_ports(
            public_outputs,
            inputs,
            map(name -> getproperty(sources, name), public_outputs);
            required,
        ),
    )
end

function PipeWireAORTC.InstrumentExport.graph_port_contracts(
    path::AbstractString; metadata::Bool = false
)
    graph = FilterGraphPipeWire.prepare_service_graph(path)
    try
        contracts = Dict(
            section => Dict(
                string(name) => PipeWireAORTC.InstrumentExport.port_contract(format) for
                (name, format) in pairs(formats(graph))
            ) for (section, formats) in (
                ("inputs", FilterGraphs.input_formats),
                ("parameters", FilterGraphs.parameter_formats),
                ("outputs", FilterGraphs.output_formats),
            )
        )
        if metadata
            boundary = Owner.metadata_profiles(graph)
            profiles = (
                inputs = boundary.input_metadata, outputs = boundary.output_metadata
            )
            for section in (:inputs, :outputs),
                (name, profile) in pairs(getproperty(profiles, section))

                contracts[string(section)][string(name)]["metadata"] = [
                    Dict("type" => r.type, "size" => r.size, "required" => r.required) for
                    r in profile.metadata
                ]
            end
        end
        return contracts
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
end

function Owner.read_bindings(graph_path::AbstractString, binding_path::AbstractString)
    entries = Owner.bindings(binding_path)
    updates = Pair{Symbol,Array}[]
    graph = FilterGraphPipeWire.prepare_service_graph(
        graph_path;
        initial_parameters = formats -> begin
            append!(updates, Owner.prepare_bindings(entries, formats))
            updates
        end,
    )
    try
        return Dict(updates)
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
end

function PipeWireAORTC.InstrumentExport.validate_feedback(
    application, graph_path, binding_path, receiver_path
)
    graphfile = joinpath(application, graph_path)
    entries = Owner.bindings(joinpath(application, binding_path))
    graph = FilterGraphPipeWire.prepare_service_graph(
        graphfile; initial_parameters = formats -> Owner.prepare_bindings(entries, formats)
    )
    try
        path = joinpath(application, receiver_path)
        PipeWireAORTC.PhysicalOffsets.prepare(path, graph)
        PipeWireAORTC.PhysicalOffsets.frame_observer(
            path, nothing, FilterGraphs.output_formats(graph)
        )
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
    return nothing
end

function Owner.run_owner(options, runtime, entries)
    Bootstrap.preparation_check!(runtime)
    options.check && throw(ArgumentError("native graph owner cannot run --check"))
    options.session_run_control ||
        throw(ArgumentError("native graph owner requires --session-run-control"))
    raw_ports = Set(parameter.port for parameter in options.parameters)
    any(entry -> entry.port in raw_ports, entries) &&
        throw(ArgumentError("FITS parameter overlaps a legacy raw startup parameter"))
    declarations = FilterGraphPipeWire.algorithm_declarations(;
        packages = options.packages,
        algorithms = options.algorithms,
        builtins = options.builtins,
    )
    Bootstrap.preparation_check!(runtime)
    workers = FilterGraphPipeWire.configure_threads(options)
    initial_parameters =
        formats -> Owner.prepare_bindings(
            entries, formats; check = () -> Bootstrap.preparation_check!(runtime)
        )
    graph = PipeWireAORTC.Common.startup_phase(options.name, "prepare graph") do
        FilterGraphPipeWire.prepare_service_graph(
            options.graph;
            algorithms = declarations,
            execution = Symbol(replace(options.execution, '-' => '_')),
            workers = options.row_workers,
            matrix_layout = options.matrix_layout,
            worker_thread_ids = workers,
            initial_parameters,
            parameters = options.parameters,
            capture_backend = options.capture_backend === nothing ? nothing :
                              Symbol(options.capture_backend),
        )
    end
    try
        # Optional provider methods loaded by declarations must be visible here.
        Base.invokelatest(run_prepared, options, runtime, graph)
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
    return nothing
end

validate_owner_feedback(graph, feedback) = nothing
function validate_owner_feedback(::FilterGraphs.PreparedComposition, feedback)
    feedback === nothing || throw(ArgumentError("composition owns its private feedback"))
    return nothing
end

function graph_node(options, graph, instance)
    validate_owner_feedback(graph, options.feedback)
    correction_properties = options.correction_properties
    !isempty(correction_properties) &&
        !isnothing(options.capture_backend) &&
        throw(
            ArgumentError(
                "captured graph owners do not support runtime correction properties"
            ),
        )
    observer =
        isempty(correction_properties) ? nothing :
        PipeWireAORTC.CorrectionLoops.Observer(
            correction_properties,
            instance;
            timeout_ms = options.correction_timeout_ms,
        )
    supervision = prepare_supervision(options, instance, graph)
    observation = correction_observation(observer, supervision)
    offsets_path = get(options, :physical_offsets, nothing)
    offsets_path === nothing ||
        (
            options.capture_backend === nothing &&
            options.execution == "complete-frame" &&
            Threads.nthreads(:default) >= 3
        ) ||
        throw(
            ArgumentError(
                "physical offsets require complete-frame CPU execution and three default threads",
            ),
        )
    offset_receiver =
        offsets_path === nothing ? nothing :
        PipeWireAORTC.PhysicalOffsets.prepare(offsets_path, graph)
    offset_clock =
        offsets_path === nothing ? nothing :
        PipeWireAORTC.PhysicalOffsets.frame_observer(
            offsets_path,
            get(observation, :frame_observer, nothing),
            FilterGraphs.output_formats(graph),
        )
    offsets_path === nothing ||
        (observation = merge(observation, (; frame_observer = offset_clock)))
    controllers = Tuple(
        Symbol(first(split(property, ':'))) for property in correction_properties
    )
    recovery =
        isempty(options.recovery_nodes) ? (;) :
        (;
            recovery = (;
                (
                    length(controllers) == 1 ? (; controller = only(controllers)) :
                    (; controllers)
                )...,
                participants = Tuple(Symbol.(options.recovery_nodes)),
                reference_timeout_ms = options.correction_timeout_ms,
            )
        )
    reference_clock = PipeWireAORTC.Common.prepare_reference_clock(options)
    common = (;
        reference_clock,
        recovery...,
        name = options.name,
        remote = options.remote,
        rate = options.rate,
        Owner.metadata_profiles(graph; feedback = options.feedback)...,
        connect = false,
        run_control = options.session_run_control,
        channel_units = options.channel_units,
    )
    node =
        isnothing(options.capture_backend) ?
        FilterGraphPipeWire.PipeWireNode(
            graph;
            common...,
            observation...,
            boundary_layout = options.boundary_layout,
            fifo_inputs = options.fifo_inputs,
            feedback = options.feedback,
        ) : FilterGraphPipeWire.PipeWireNode(graph; common...)
    return (; node, observer, offset_receiver, offset_clock)
end

function warm_graph!(node, graph, options)
    warmup = get(options, :chopped_warmup, nothing)
    samples = warmup === nothing ? nothing : chopped_warmup_samples(graph, options, warmup)
    FilterGraphPipeWire.prepare!(
        node;
        execution = options.execution == "row-block" ? :row_block : :complete_frame,
        required_outputs = options.warmup_outputs,
        samples,
    )
    return nothing
end

function Owner.precompile_graph_warmup(args)
    _, graph_args, fits, properties, timeout, recovery, supervision, offsets, warmup =
        Owner.arguments(args)
    options = Owner.graph_options(
        FilterGraphPipeWire, graph_args, properties, timeout, recovery, supervision, offsets, warmup,
    )
    # Offline construction is limited to complete-frame CPU owners without
    # optional physical offset transport or progressive worker placement.
    options.capture_backend === nothing && options.execution == "complete-frame" &&
        options.row_workers == 0 && offsets === nothing || return nothing
    entries = fits === nothing ? Owner.FITSBinding[] : Owner.bindings(fits)
    declarations = FilterGraphPipeWire.algorithm_declarations(;
        packages = options.packages, algorithms = options.algorithms, builtins = options.builtins,
    )
    graph = FilterGraphPipeWire.prepare_service_graph(
        options.graph; algorithms = declarations, execution = :complete_frame,
        matrix_layout = options.matrix_layout, initial_parameters = formats ->
            Owner.prepare_bindings(entries, formats), parameters = options.parameters,
    )
    try
        (; node, observer) = graph_node(options, graph, Int64(1))
        try
            warm_graph!(node, graph, options)
        finally
            try
                close(node)
            finally
                isnothing(observer) || close(observer)
            end
        end
    finally
        FilterGraphPipeWire.close_execution(graph)
    end
    return nothing
end

function run_prepared(options, runtime, graph)
    Bootstrap.preparation_check!(runtime)
    (; node, observer, offset_receiver, offset_clock) =
        graph_node(options, graph, runtime.transport.endpoint.instance)
    offsets_path = get(options, :physical_offsets, nothing)
    try
        isnothing(observer) || PipeWireAORTC.CorrectionLoops.check_ready(observer)
        isnothing(observer) || PipeWireAORTC.CorrectionLoops.attach_timers!(
            observer,
            runtime.transport.loop,
            () -> PipeWireAO.notify_properties!(node.filter),
        )
        if isnothing(options.capture_backend)
            PipeWireAORTC.Common.startup_phase(options.name, "warm up graph") do
                warm_graph!(node, graph, options)
            end
        end
        Bootstrap.preparation_check!(runtime)
        Bootstrap.prepared!(runtime)
        ticket = Bootstrap.take_connect!(runtime)
        Bootstrap.connecting!(
            runtime,
            ticket;
            ready = () ->
                FilterGraphPipeWire.node_id(node) !== nothing &&
                PipeWireAO.isrunning(node) &&
                FilterGraphPipeWire.node_state(node) in (
                    PipeWireAO.NDARRAY_FILTER_STATE_PAUSED,
                    PipeWireAO.NDARRAY_FILTER_STATE_STREAMING,
                ),
            quit = () -> FilterGraphPipeWire.quit!(node),
        )
        Bootstrap.check_connect!(runtime, ticket)
        FilterGraphPipeWire.connect!(node)
        Bootstrap.check_connect!(runtime, ticket)
        if offsets_path === nothing
            FilterGraphPipeWire.run!(node)
        else
            PipeWireAORTC.PhysicalOffsets.with_receiver(
                offset_receiver; node, remote = options.remote, frame_clock = offset_clock
            ) do
                FilterGraphPipeWire.run!(node)
            end
        end
    catch error
        owner_cancelled(error, runtime) && return nothing
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

chopped_warmup_input(graph, formats, input) = keys(formats) == (input,)
chopped_warmup_input(::FilterGraphs.PreparedComposition, formats, input) =
    input in keys(formats)

function chopped_warmup_samples(graph, options, warmup)
    options.execution == "complete-frame" &&
    options.feedback === nothing &&
    options.capture_backend === nothing ||
        throw(ArgumentError("chopped warmup requires ordinary complete-frame execution"))
    formats = FilterGraphs.input_formats(graph)
    chopped_warmup_input(graph, formats, warmup.input) ||
        throw(ArgumentError("chopped warmup requires its declared image input"))
    format = getproperty(formats, warmup.input)
    format.element_type === Float32 && length(format.shape) == 2 ||
        throw(ArgumentError("chopped warmup requires a Float32 image"))
    identity =
        sequence -> FilterGraphAlgorithms.SampleAcquisitionIdentity(
            ntuple(_ -> UInt8(0xa5), 16), UInt64(1), UInt64(sequence)
        )
    samples = ntuple(3) do index
        fringed = isodd(index)
        metadata = FilterGraphAlgorithms.SampleMetadata(
            index;
            terminal = true,
            trigger_high = fringed == warmup.trigger_high_is_fringed,
            chopped_image_kind = fringed ? FilterGraphAlgorithms.ChoppedImageFringed :
                                 FilterGraphAlgorithms.ChoppedImageUnfringed,
            acquisition_identity = identity(index),
            exposure_duration_nanoseconds = warmup.exposure_duration_ns,
        )
        (;
            inputs = NamedTuple{(warmup.input,)}((ones(Float32, format.shape),)),
            metadata = NamedTuple{(warmup.input,)}((metadata,)),
            expected = index == 1 ? FilterGraphAlgorithms.SccPixelResidualIncompletePair :
                       nothing,
        )
    end
    return chopped_warmup_samples(graph, formats, warmup, samples)
end

chopped_warmup_samples(graph, formats, warmup, samples) = samples
function chopped_warmup_samples(
    ::FilterGraphs.PreparedComposition, formats, warmup, samples
)
    # Independently prime the remaining camera branches. These measurements
    # are unpublished, and the ordinary preparation boundary resets all state.
    others = filter(!=(warmup.input), keys(formats))
    additional = map(others) do name
        camera = getproperty(formats, name)
        camera.element_type === Float32 && length(camera.shape) == 2 || throw(
            ArgumentError("chopped composition warmup requires Float32 camera inputs")
        )
        metadata = FilterGraphAlgorithms.SampleMetadata(
            1;
            terminal = true,
            acquisition_identity = FilterGraphAlgorithms.SampleAcquisitionIdentity(
                ntuple(_ -> UInt8(0xa6), 16), UInt64(1), UInt64(1)
            ),
            exposure_duration_nanoseconds = warmup.exposure_duration_ns,
        )
        (;
            inputs = NamedTuple{(name,)}((ones(Float32, camera.shape),)),
            metadata = NamedTuple{(name,)}((metadata,)),
            expected = nothing,
        )
    end
    # Native independent-input callbacks can also carry simultaneous arrivals.
    # Exercise that path before admission rather than compiling it on a frame.
    together = NamedTuple{keys(formats)}(
        map(keys(formats)) do name
            camera = getproperty(formats, name)
            ones(Float32, camera.shape)
        end,
    )
    combined_metadata = NamedTuple{keys(formats)}(
        map(keys(formats)) do name
            sequence = name === warmup.input ? UInt64(4) : UInt64(2)
            domain = name === warmup.input ? UInt8(0xa5) : UInt8(0xa6)
            annotations =
                name === warmup.input ?
                (;
                    trigger_high = !warmup.trigger_high_is_fringed,
                    chopped_image_kind = FilterGraphAlgorithms.ChoppedImageUnfringed,
                ) : (;)
            FilterGraphAlgorithms.SampleMetadata(
                sequence;
                terminal = true,
                acquisition_identity = FilterGraphAlgorithms.SampleAcquisitionIdentity(
                    ntuple(_ -> domain, 16), UInt64(1), sequence
                ),
                exposure_duration_nanoseconds = warmup.exposure_duration_ns,
                annotations...,
            )
        end,
    )
    return (
        samples...,
        additional...,
        (; inputs = together, metadata = combined_metadata, expected = nothing),
    )
end

owner_cancelled(::InterruptException, runtime) = Bootstrap.clean_cancel(runtime)
owner_cancelled(error, runtime) = false

end
