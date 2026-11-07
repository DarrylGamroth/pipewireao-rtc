# Managed external-pupil optics use the ordinary AOS exposure owner and native
# bootstrap/source controls. No controller or mirror lives in this owner.
module ExternalPupilOwner
using ..PipeWireAORTCAOSExt:
    owner_cancelled,
    Owner,
    Bootstrap,
    SourceControl,
    Backends,
    target,
    OwnerState,
    execution_properties
using PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: external_pupil_contract, optical_execution_graph
using SHA
import PipeWireAORTC
import Clocks
import PipeWireAORTC.Common: prepare_reference_clock
const IC = PipeWireAORTC.InstrumentConfiguration
const Optical = AdaptiveOpticsSimPipeWireHIL.ExternalPupil

function pupil_contract(declaration, configured)
    optical = declaration.instrument.document["optical_input"]
    return external_pupil_contract(;
        pupil_resolution = configured["pupil_resolution"],
        diameter_m = optical["diameter_m"],
        plane = optical["plane"],
        curvature = optical["curvature"],
        registration = optical["registration"],
        wavelength_um = haskey(configured, "spectra") ? nothing :
                        configured["wavelength_um"],
    )
end

function spectral_properties(configured, name)
    spectrum =
        haskey(configured, "spectra") ? configured["spectra"][string(name)] :
        Dict(
            "wavelength_um" => configured["wavelength_um"],
            "fractional_bandwidth" => 0,
            "samples" => 1,
            "filter" => "none",
        )
    properties = Dict(
        "optics.central-wavelength-m" => string(spectrum["wavelength_um"] * 1e-6),
        "optics.fractional-bandwidth" => string(spectrum["fractional_bandwidth"]),
        "optics.spectral-samples" => string(spectrum["samples"]),
        "optics.filter" => string(spectrum["filter"]),
    )
    spectrum["fractional_bandwidth"] == 0 &&
        (properties["optics.wavelength-m"] = string(spectrum["wavelength_um"] * 1e-6))
    return properties
end

function optical_execution_properties(plant, name; prefix = "optics.", unfringed = false)
    graph = optical_execution_graph(plant, name; unfringed)
    independent =
        unfringed ? getproperty(plant.observations, name).chopping.unfringed :
        getproperty(plant.graphs, name)
    properties = execution_properties(graph; prefix)
    if graph !== independent
        # Native properties are fixed at preparation. Describe both admitted
        # executions; their node counts are not a per-frame selection report.
        properties[prefix*"execution-scope"] = "prepared"
        merge!(
            properties, execution_properties(independent; prefix = prefix * "independent.")
        )
    end
    return properties
end

function sensor_contract(declaration, configured, plant, name, identity)
    graph = getproperty(plant.graphs, name)
    observation = getproperty(plant.observations, name)
    sampling = optical_sampling_m(
        AlgorithmGraphs.prepared_graph_node(graph, observation.sampling_node)
    )
    response = get(observation, :response, nothing)
    image =
        response === nothing ? graph_output(graph, observation.output) :
        graph_output(response.graph, response.output)
    schema =
        response === nothing ?
        "org.adaptiveopticssim.optical-intensity/sha256-" *
        bytes2hex(sha256(join((identity, name, sampling, size(image)), "\n"))) *
        "/1" : response.frame_schema
    path = declaration.instrument.document["optical_paths"][string(name)]
    sensor = declaration.instrument.document["wavefront_sensors"][path["sensor"]]
    haskey(sensor, "detector_shape") &&
        Tuple(sensor["detector_shape"]) != size(image) &&
        throw(DimensionMismatch("sensor detector_shape differs from its optical product"))
    get(sensor, "expected_schema", schema) == schema ||
        throw(ArgumentError("sensor expected_schema differs from its optical product"))
    execution = optical_execution_properties(plant, name)
    response === nothing ||
        merge!(execution, execution_properties(response.graph; prefix = "detector."))
    if response !== nothing
        acquisition = get(sensor, "acquisition", Dict())
        execution["detector.roi-origin-known"] = string(haskey(acquisition, "roi_origin"))
        execution["detector.roi-shape"] = join(size(image), ",")
        if haskey(acquisition, "roi_origin")
            execution["detector.roi-origin"] = join(acquisition["roi_origin"], ",")
        end
    end
    if hasproperty(observation, :chopping)
        merge!(
            execution,
            optical_execution_properties(
                plant, name; unfringed = true, prefix = "optics.unfringed."
            ),
        )
    end
    return (;
        image,
        schema,
        properties = merge(
            spectral_properties(configured, name),
            execution,
            Dict(
                "optics.model-sha256" => String(chopprefix(identity, "sha256:")),
                "optics.branch" => string(name),
                "optics.sampling-m" => string(sampling),
                "optics.axis-order" => "y,x",
                "optics.pts-units" => "simulation_nanoseconds",
                "optics.exposure-duration-ns" =>
                    string(getproperty(plant.exposures, name).duration_ns),
                "optics.units" =>
                    response === nothing ? "relative_intensity" :
                    "declared_detector_output",
                "detector.name" => sensor["detector"]["name"],
            ),
        ),
    )
end

function prepare(
    path;
    settings = NamedTuple(),
    target = Backends.HostComputeDevice(),
    chopping = NamedTuple(),
    check = () -> nothing,
)
    declaration = IC.load_simulation(path)
    if get(get(declaration.document, "optical_model", Dict()), "format", nothing) == "zemax"
        AdaptiveOpticsSim.Optics.Zemax.validate_provenance(declaration.directory)
    end
    configured = IC.settings(declaration, settings)
    identity = IC.prescription_identity(declaration, configured)
    check()
    plant = IC.prepare_external_pupil(path; settings, target, chopping)
    # Establish immutable optical sampling without consuming detector draws.
    foreach(step_graph!, values(plant.graphs))
    sensors = map(keys(plant.graphs)) do name
        sensor_contract(declaration, configured, plant, name, identity)
    end
    reset_external_pupil!(plant)
    check()
    return (;
        plant,
        declaration,
        configured,
        identity,
        chopping,
        pupil = pupil_contract(declaration, configured),
        sensors = NamedTuple{keys(plant.graphs)}(sensors),
    )
end

# RTC resolves authored assets; HIL receives only prepared AOS values.
function prepare_clocked_source(options, science; check = () -> nothing)
    source = IC.prepare_system(
        options.plant.definition;
        settings = options.plant.settings,
        simulation_graph = options.source_graph,
        target = Backends.HostComputeDevice(),
    )
    declaration = IC.load_simulation(options.plant.definition)
    configured = IC.settings(declaration, options.plant.settings)
    size(graph_input(source.graph, options.command_input)) == (options.command_count,) ||
        throw(DimensionMismatch("clocked source command differs from declared count"))
    amplitude = IC.binding_values(
        declaration,
        configured,
        declaration.document["bindings"][options.source_amplitude_binding],
    )
    return Optical.prepare_clocked_source(
        science;
        source,
        command_input = options.command_input,
        amplitude,
        pupil_axes = options.source_pupil_axes,
        period_ns = options.period_ns,
        check,
    )
end

function clocked_command_option(options)
    return PipeWireArrayStreamOptions(;
        node_name = options.command_node,
        media_name = options.mirror * " native command",
        buffers = options.command_buffers,
        reference_clock = prepare_reference_clock(options),
        metadata = (
            MetadataRequirement(SPA.META_REFERENCE_TIMESTAMP; required = true),
            MetadataRequirement(SPA.META_ACQUISITION_IDENTITY),
            MetadataRequirement(SPA.META_EXPOSURE_TIMING),
        ),
        schema = options.command_schema,
        format = NdArrayFormat(
            NdArray.F32_LE, (options.command_count,); layout = NdArray.ROW_MAJOR
        ),
        properties = Dict(
            "optics.command-units" => options.command_units,
            "optics.calibration-identity" => options.calibration_identity,
        ),
    )
end

function Owner.prepare_external_pupil_science(options; check = () -> nothing)
    check()
    science = prepare(
        options.plant.definition;
        settings = options.plant.settings,
        chopping = options.plant.chopping,
        target = target(options),
        check,
    )
    return options.version == 6 ? prepare_clocked_source(options, science; check) : science
end

function PipeWireAORTC.InstrumentExport.external_pupil_port_contracts(
    path; settings = NamedTuple(), chopping = NamedTuple()
)
    science = prepare(path; settings, chopping)
    contract(format, schema) =
        Dict("shape" => collect(format), "element-type" => "F32_LE", "schema" => schema)
    return Dict(
        "pupil" => contract(science.pupil.shape, science.pupil.schema),
        "sensors" => Dict(
            string(name) => contract(size(sensor.image), sensor.schema) for
            (name, sensor) in pairs(science.sensors)
        ),
    )
end

function report!(options, mailbox, state)
    Owner.write_report(options, state, state.generation, mailbox.instance)
    SourceControl.report_ready!(mailbox, state.generation, state.sequence)
    return nothing
end

function consume_control!(
    options,
    mailbox,
    filter,
    state,
    reset_owner!;
    now_ns::Int64 = Clocks.time_nanos(Clocks.SystemNanoClock()),
)
    mailbox.ready[] || return nothing
    loop = options.bootstrap_runtime.transport.loop
    kind, token, running = with_thread_loop_lock(loop) do _
        SourceControl.pending(mailbox)
    end
    if kind != SourceControl.INITIAL
        result = SourceControl.apply!(
            state, kind, token, running, now_ns, Int64(1), reset_owner!
        )
        kind == SourceControl.RESET && result == 0 && report!(options, mailbox, state)
        with_thread_loop_lock(loop) do _
            SourceControl.publish!(
                mailbox, filter, kind, token, result, state, state.generation
            )
        end
    end
    with_thread_loop_lock(loop) do _
        SourceControl.publish_rejection!(mailbox, filter, state, state.generation)
    end
    return nothing
end

# This adapter owns RTC decisions only. Simulation state belongs to HIL.
function sync_state!(state, execution)
    status = Optical.snapshot(execution)
    state.generation = status.generation
    state.sequence = status.sequence
    state.deadline_ns = status.deadline_ns
    return nothing
end

struct Control{O,M,S,F}
    options::O
    mailbox::M
    state::S
    filter::F
end

function (control::Control)(execution, streams, now_ns::Int64)
    (; options, mailbox, state, filter) = control
    sync_state!(state, execution)
    SourceControl.observe_clock!(state, now_ns)
    Bootstrap.cancelled(options.bootstrap_runtime) && return Optical.Stop()
    reset_owner! = () -> begin
        Optical.reset!(execution, streams)
        sync_state!(state, execution)
    end
    consume_control!(options, mailbox, filter, state, reset_owner!; now_ns)
    Bootstrap.cancelled(options.bootstrap_runtime) && return Optical.Stop()
    return state.running ? Optical.Run(state.deadline_ns) : Optical.Hold()
end

Base.@nospecializeinfer function run_streams!(
    @nospecialize(options),
    science,
    mailbox,
    state,
    execution,
    @nospecialize(owner),
    @nospecialize(ticket);
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    @info "Optical owner startup" phase = :streams_entry at_ns = Clocks.time_nanos(clock)
    runtime = options.bootstrap_runtime
    transport = runtime.transport
    clocked = options.version == 6
    filter = nothing
    try
        with_thread_loop_lock(transport.loop) do _
            filter = Filter(
                transport.core,
                options.control_node;
                properties = merge(
                    SourceControl.source_properties(mailbox),
                    optical_execution_properties(
                        science.plant,
                        first(keys(science.plant.graphs));
                        prefix = "aos.simulation.",
                    ),
                    Dict(
                        "node.name" => options.control_node,
                        "media.class" => "Control",
                        "aos.simulation.mode" =>
                            clocked ? "clocked-optical" : "external-pupil",
                        "aos.simulation.backend" => string(options.backend),
                        "aos.simulation.device" => string(options.device),
                        "aos.simulation.calibration-identity" =>
                            options.calibration_identity,
                        "aos.simulation.configuration-sha256" =>
                            options.configuration_sha256,
                        "aos.simulation.prescription-identity" => science.identity,
                    ),
                ),
                on_param_changed = SourceControl.ParameterChanged(mailbox),
            )
            connect!(
                filter;
                flags = FILTER_ASYNC | FILTER_INACTIVE,
                params = mailbox.parameters.params,
            )
        end
        while true
            Bootstrap.check_connect!(runtime, ticket)
            ready = with_thread_loop_lock(transport.loop) do _
                node_id(filter) ∉ (UInt32(0), typemax(UInt32))
            end
            ready &= all(eachindex(owner.streams)) do index
                with_array_stream(owner, index) do stream
                    node_id(stream) ∉ (UInt32(0), typemax(UInt32)) &&
                        stream_state(stream) in (
                            PipeWireAO.LibPipeWire.PW_STREAM_STATE_PAUSED,
                            PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING,
                        )
                end
            end
            ready && break
            sleep(0.001)
        end
        @info "Optical owner startup" phase = :streams_ready at_ns = Clocks.time_nanos(
            clock
        )
        @info "Optical owner startup" phase = :transport_warmup_begin at_ns = Clocks.time_nanos(
            clock
        )
        Optical.prepare_transport!(execution, owner)
        Bootstrap.check_connect!(runtime, ticket)
        @info "Optical owner startup" phase = :transport_warmup_end at_ns = Clocks.time_nanos(
            clock
        )
        control = Control(options, mailbox, state, filter)
        precompile(
            Core.kwcall,
            (
                NamedTuple{(:clock,),Tuple{typeof(clock)}},
                typeof(Optical.run!),
                typeof(control),
                typeof(execution),
                typeof(owner),
            ),
        ) || error("external-pupil admitted loop preparation failed")
        Bootstrap.check_connect!(runtime, ticket)
        Bootstrap.connected!(runtime, ticket)
        Bootstrap.await_connected!(runtime, ticket)
        Optical.run!(control, execution, owner; clock)
    finally
        sync_state!(state, execution)
        Bootstrap.finishing!(runtime)
        with_thread_loop_lock(transport.loop) do _
            filter === nothing || close(filter)
        end
    end
    return nothing
end

# Warm the prepared model without publishing synthetic camera frames.
function prepare_stream_execution!(
    options,
    science,
    mailbox,
    state;
    clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock(),
)
    options.owner_check()
    clocked = options.version == 6
    execution = Optical.prepare(
        science;
        clocked,
        command_count = clocked ? options.command_count : 0,
        command_limit = clocked ? options.command_limit : Inf,
        pacing_period_ns = clocked ? options.pacing_period_ns : 0,
    )
    Optical.warmup!(execution; check = options.owner_check)
    options.owner_check()
    precompile(
        run_streams!,
        (Any, typeof(science), typeof(mailbox), typeof(state), typeof(execution), Any, Any),
    ) || error("external-pupil control-loop preparation failed")
    options.owner_check()
    return execution
end

function Owner.run_external_pupil_owner(
    options; clock::Clocks.AbstractNanoClock = Clocks.SystemNanoClock()
)
    runtime = options.bootstrap_runtime
    options = merge(
        options,
        (; configuration_sha256 = PipeWireAORTC.Common.sha256_file(options.config_path)),
    )
    state = OwnerState()
    mailbox = SourceControl.Mailbox(Int64(rand(UInt64) % UInt64(typemax(Int64))) + Int64(1))
    failures = Exception[]
    try
        science = Owner.prepare_external_pupil_science(options; check = options.owner_check)
        report!(options, mailbox, state)
        streams = Optical.stream_options(
            science,
            options.pupil_node,
            options.sensor_nodes;
            sensor_buffers = options.sensor_buffers,
            input_option = options.version == 6 ? clocked_command_option(options) : nothing,
            reference_clock = prepare_reference_clock(options),
        )
        execution = prepare_stream_execution!(options, science, mailbox, state; clock)
        @info "Optical owner startup" phase = :prepared at_ns = Clocks.time_nanos(clock)
        Bootstrap.prepared!(runtime)
        ticket = Bootstrap.take_connect!(runtime)
        @info "Optical owner startup" phase = :connect_received at_ns = Clocks.time_nanos(
            clock
        )
        Bootstrap.check_connect!(runtime, ticket)
        with_array_streams(
            streams;
            remote = options.remote,
            input = (true, map(_ -> false, keys(science.sensors))...),
        ) do owner
            @info "Optical owner startup" phase = :streams_constructed at_ns = Clocks.time_nanos(
                clock
            )
            cpu = get(options, :pipewire_cpu, nothing)
            cpu === nothing || PipeWireAORTC.Placement.pin_loop!(
                owner.loop, cpu; check = options.owner_check
            )
            run_streams!(options, science, mailbox, state, execution, owner, ticket; clock)
        end
    catch error
        if !(owner_cancelled(error, runtime))
            @error "Optical owner failed" exception = (error, catch_backtrace())
            push!(failures, error)
            Bootstrap.fault!(runtime, error)
        end
    finally
        Bootstrap.finishing!(runtime)
        state.running = false
        try
            Owner.write_report(options, state, state.generation, mailbox.instance; failures)
        catch error
            push!(failures, error)
        end
    end
    isempty(failures) ||
        throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

end
