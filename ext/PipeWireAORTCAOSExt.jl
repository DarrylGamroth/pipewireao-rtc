module PipeWireAORTCAOSExt

using PipeWireAORTC
using AdaptiveOpticsSim
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSimPipeWireHIL
using PipeWireAO
using YAML

const Owner = PipeWireAORTC.AOSOwner
const Bootstrap = PipeWireAORTC.NativeOwnerBootstrapRuntime
const SourceControl = PipeWireAORTC.NativeSourceControl
const Backends = AdaptiveOpticsSim.Backends

include("aos/optical_observation.jl")
include("aos/phase_timing.jl")
include("aos/metadata.jl")
include("aos/graph_adapters.jl")
include("aos/instruments.jl")
include("aos/pupil_output.jl")

mutable struct OwnerState
    running::Bool
    completed::Bool
    sequence::UInt64
    last_request_id::Int64
    deadline_ns::UInt64
    generation::Int64
end
OwnerState() = OwnerState(false, false, 0, 0, 0, 1)

target_device(::Val{:cpu}, device) = Backends.HostComputeDevice()
target_device(::Val{:cuda}, device) = Backends.AcceleratorComputeDevice(Backends.CUDABackend(), device)
target_device(::Val{:amdgpu}, device) = Backends.AcceleratorComputeDevice(Backends.AMDGPUBackend(), device)

function target(options)
    device = target_device(Val(options.backend), options.device)
    availability = Backends.compute_device_availability(device)
    Backends.compute_device_is_available(availability) || throw(ArgumentError(
        "requested $(options.backend) backend is unavailable: $(Backends.compute_device_unavailable_reason(availability))"))
    return device
end

function copy_to_target(device, values)
    destination = Backends.allocate_device_array(device, eltype(values), size(values)...)
    copyto!(destination, values)
    return destination
end

"Validate all graph binding names and declared timing before reading FITS."
function validate_graph(options)
    document = PipeWireAORTC.Common.read_yaml(options.graph)
    inputs = get(document, "inputs", Any[])
    command = filter(entry -> get(entry, "name", nothing) == string(options.command_input), inputs)
    length(command) == 1 && get(only(command), "binding", nothing) == string(options.command_input) ||
        throw(ArgumentError("command_input must name one graph input with the same binding"))
    outputs = get(document, "outputs", Any[])
    count(entry -> get(entry, "name", nothing) == string(options.frame_output), outputs) == 1 ||
        throw(ArgumentError("frame_output must name exactly one graph output"))
    required = Set{Symbol}()
    for (section, key) in (("inputs", "binding"), ("parameters", "binding"), ("delayed_links", "initial"))
        for entry in get(document, section, Any[])
            push!(required, Owner.identifier(get(entry, key, nothing), "graph $section $key"))
        end
    end
    supplied = Set([options.command_input; [entry.binding for entry in options.artifacts]])
    required == supplied || throw(ArgumentError("graph external bindings differ from configured command/FITS bindings"))
    for node in get(document, "nodes", Any[])
        config = get(node, "config", Dict())
        if haskey(config, "atmosphere_step")
            step = config["atmosphere_step"]
            step isa Real && !(step isa Bool) && isfinite(step) &&
                isapprox(step, options.period_ns / 1e9; rtol=1e-12, atol=0) ||
                throw(ArgumentError("graph atmosphere_step differs from declared model period"))
        end
        if haskey(config, "exposure_duration_s")
            exposure = config["exposure_duration_s"]
            exposure isa Real && !(exposure isa Bool) && isfinite(exposure) &&
                isapprox(exposure, options.exposure_ns / 1e9; rtol=1e-12, atol=0) ||
                throw(ArgumentError("graph exposure_duration_s differs from declared exposure"))
        end
    end
    return nothing
end

"Construct a declared AOS graph without an instrument implementation package."
function prepare_declared_science(options, device; check=()->nothing)
    check()
    validate_graph(options)
    check()
    artifacts = Owner.prepare_bindings(options.artifacts; check)
    bindings = Pair{Symbol,Any}[]
    command = Backends.allocate_device_array(device, Float32, options.command_count)
    fill!(command, 0.0f0)
    push!(bindings, options.command_input => command)
    for (entry, artifact) in zip(options.artifacts, artifacts)
        check()
        push!(bindings, entry.binding => copy_to_target(device, artifact.data))
    end
    check()
    definition = load_algorithm_graph(options.graph; bindings=(; bindings...))
    execution = options.backend === :cpu ? StreamGraphExecution() : CapturedGraphExecution()
    graph = prepare_algorithm_graph(definition; target=device, execution)
    check()
    boundary = prepare_graph_hil_boundary(graph;
        command_input=options.command_input, frame_output=options.frame_output)
    return (; definition, graph, boundary, target=device, artifacts)
end

function wire_configuration(options)
    return PipeWireHILConfiguration(remote=options.remote,
        frame_node_name=options.control_node, command_node_name=options.command_node,
        frame_schema=options.frame_schema, command_schema=options.command_schema,
        rate=SPA.Fraction(UInt32(options.rate), UInt32(1)),
        exposure_duration_ns=options.exposure_ns, frame_encoding=options.frame_encoding,
        command_scale=options.command_scale)
end

function prepare_instrument_science(options, device; check=()->nothing)
    plant_module = options.plant_module
    execution = options.backend === :cpu ? StreamGraphExecution() : CapturedGraphExecution()
    system = Base.invokelatest(plant_module.prepare_hil_system, options.plant.settings;
        target=device, execution)
    check()
    AdaptiveOpticsSimPipeWireHIL.validate_hil_system(system;
        command_input=options.command_input, frame_output=options.frame_output,
        command_shape=(options.command_count,), frame_shape=options.frame_shape)
    configuration = Base.invokelatest(plant_module.pipewire_configuration, system, options.remote;
        frame_node_name=options.control_node, command_node_name=options.command_node,
        frame_encoding=options.frame_encoding, frame_schema=options.frame_schema,
        command_schema=options.command_schema, command_scale=options.command_scale)
    validate_configuration(configuration, options)
    # The builder records the actual model cadence independently of exposure.
    period_ns = round(Int, Float64(system.frame_period_s) * 1e9)
    period_ns == options.period_ns || throw(ArgumentError(
        "prepared model period differs from configured model period"))
    return (; definition=system.definition, graph=system.graph, boundary=system.boundary,
        target=device, artifacts=(), configuration)
end

function validate_configuration(configuration::PipeWireHILConfiguration, options)
    configuration.remote == options.remote &&
        configuration.frame_node_name == options.control_node &&
        configuration.command_node_name == options.command_node ||
        throw(ArgumentError("prepared wire endpoint names differ from configuration"))
    configuration.frame_schema == options.frame_schema &&
        configuration.command_schema == options.command_schema &&
        configuration.frame_encoding === options.frame_encoding &&
        configuration.command_scale == options.command_scale ||
        throw(ArgumentError("prepared wire contract differs from configuration"))
    UInt64(configuration.rate.num) == UInt64(options.rate) * UInt64(configuration.rate.denom) ||
        throw(ArgumentError("prepared frame rate differs from configuration"))
    configuration.exposure_duration_ns == options.exposure_ns ||
        throw(ArgumentError("prepared detector exposure differs from configuration"))
    return nothing
end

function validate_command_buffers(command::AbstractArray, count::Integer)
    size(command) == (count,) || throw(DimensionMismatch("AOS command shape differs from configured count"))
    return nothing
end
function validate_command_buffers(commands::NamedTuple, counts::NamedTuple)
    Set(keys(commands)) == Set(keys(counts)) || throw(ArgumentError("AOS command buffer names differ from configuration"))
    for name in keys(commands)
        validate_command_buffers(commands[name], counts[name])
    end
    return nothing
end
zero_command_buffers!(command::AbstractArray) = fill!(command, 0.0f0)
zero_command_buffers!(commands::NamedTuple) = foreach(zero_command_buffers!, values(commands))
command_streams(stream) = (stream,)
command_streams(streams::NamedTuple) = values(streams)

# A named exchange completes after every command has arrived. Diagnostics use
# the latest receipt from that same source frame, retaining the scalar contract.
completed_frame_timing(timing) = timing
function completed_frame_timing(timings::NamedTuple)
    first_timing = first(values(timings))
    all(timing -> timing.sequence == first_timing.sequence &&
        timing.source_published_nanoseconds == first_timing.source_published_nanoseconds, values(timings)) ||
        error("completed command timings differ from their common source frame")
    received = maximum(timing -> timing.command_received_nanoseconds, values(timings))
    return PipeWireFrameCommandTiming(first_timing.sequence,
        first_timing.source_published_nanoseconds, received)
end

"Prepare and warm the exact plant boundary once, then restore its initial cursor."
function Owner.prepare_science(options; check=()->nothing)
    check()
    device = target(options)
    check()
    science = options.version == 3 ? prepare_configured_science(options,device;check) :
        options.plant === nothing ? prepare_declared_science(options, device; check) :
        prepare_instrument_science(options, device; check)
    check()
    boundary = science.boundary
    size(hil_frame_buffer(boundary)) == options.frame_shape ||
        throw(DimensionMismatch("AOS detector frame differs from configured $(options.frame_shape)"))
    validate_command_buffers(hil_command_buffer(boundary), options.command_count)
    driver = FixedStepModelTimeDriver(PeriodicSchedule(; period_ns=options.period_ns))
    warm = step_hil_frame_at!(boundary, driver)
    check()
    for value in hil_frame_buffer(boundary)
        isfinite(value) && 0 <= value <= typemax(UInt16) ||
            throw(ArgumentError("prepared detector frame cannot encode as UInt16"))
    end
    zero_command_buffers!(hil_command_buffer(boundary))
    adopt_hil_command!(boundary, warm.sequence)
    reset_hil_boundary!(boundary, driver)
    check()
    configuration = options.plant === nothing ? wire_configuration(options) : science.configuration
    return merge(science, (; driver, configuration))
end

"Record readiness only after its actual operational report has been saved."
function save_report!(options, mailbox, state, generation; failures=())
    Owner.write_report(options, state, generation, mailbox.instance; failures)
    SourceControl.report_ready!(mailbox, generation, state.sequence)
    return nothing
end

"Prepare the saved initial cursor before any native source Props can be visible."
function prepare_source_control(options, state, source_instance)
    mailbox = SourceControl.Mailbox(source_instance)
    save_report!(options, mailbox, state, Int64(1))
    return mailbox
end

# The idle poll forwards this callable; explicit specialization keeps its
# prepared science captures from being boxed again on every poll.
function consume_control!(options, mailbox, pipewire, state, pacing_period,
        reset_owner!::F, phase=nothing) where {F}
    mailbox.ready[] || return nothing
    kind, token, requested_running = with_frame_stream(pipewire) do _
        SourceControl.pending(mailbox)
    end
    if kind != SourceControl.INITIAL
        result = SourceControl.apply!(state, kind, token, requested_running,
            time_ns(), max(pacing_period, UInt64(1)), reset_owner!)
        request_generation = Int64(frame_acquisition_generation(pipewire))
        if result == 0 && !state.running
            save_phase_timing!(phase)
        end
        if kind == SourceControl.RESET && result == 0
            save_report!(options, mailbox, state, request_generation)
        end
        with_frame_stream(pipewire) do stream
            SourceControl.publish!(mailbox, stream, kind, token, result, state, request_generation)
        end
    end
    generation = Int64(frame_acquisition_generation(pipewire))
    with_frame_stream(pipewire) do stream
        SourceControl.publish_rejection!(mailbox, stream, state, generation)
    end
    return nothing
end

function wait_registered!(pipewire, runtime, ticket, pupil=nothing)
    while true
        Bootstrap.check_connect!(runtime, ticket)
        registered = with_frame_stream(pipewire) do frame
            streams = (frame, command_streams(pipewire.command_stream)...)
            all(stream -> node_id(stream) != typemax(UInt32) && stream_state(stream) in
                (PipeWireAO.LibPipeWire.PW_STREAM_STATE_PAUSED,
                    PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING), streams)
        end
        Bootstrap.check_connect!(runtime, ticket)
        registered && PupilOutput.registered(pupil) && return nothing
        sleep(min(0.005, max(0.0, ticket.deadline - Bootstrap.Client.monotonic())))
    end
end

function next_deadline(deadline::UInt64, period::UInt64, now::UInt64)
    candidate = Base.checked_add(deadline, period)
    missed = now >= candidate ? div(now - candidate, period) + UInt64(1) : UInt64(0)
    return Base.checked_add(candidate, Base.checked_mul(missed, period))
end

function run_prepared!(options, science, pipewire, observation, mailbox, state, phase=nothing, pupil=nothing)
    runtime = options.bootstrap_runtime
    reset_owner! = () -> begin
        # Drain optional asynchronous snapshots before graph reset. Native
        # source controls are applied only here, after the preceding exchange.
        OpticalObservation.drain!(observation)
        PupilOutput.drain!(pupil; check=options.owner_check)
        save_phase_timing!(phase)
        reset_pipewire_hil!(pipewire, science.driver)
        # The plant reset has committed this empty cursor even if optional
        # observation rewarming subsequently fails before the control ACK.
        state.generation = Int64(frame_acquisition_generation(pipewire))
        state.sequence = 0
        PupilOutput.reset!(pupil, UInt64(state.generation); check=options.owner_check)
        state.completed = false
        state.deadline_ns = 0
        reset_phase_timing!(phase, state.generation)
        OpticalObservation.reset!(observation, pipewire; check=options.owner_check,
            cpu=get(options, :optical_diagnostics_cpu, nothing))
    end
    ticket = Bootstrap.take_connect!(runtime)
    Bootstrap.check_connect!(runtime, ticket)
    start!(pipewire)
    wait_registered!(pipewire, runtime, ticket, pupil)
    Bootstrap.connected!(runtime, ticket)
    Bootstrap.await_connected!(runtime, ticket)
    println("SIMULATOR_CONNECTED sequence=0 held=true")
    flush(stdout)
    while !Bootstrap.cancelled(runtime)
        consume_control!(options, mailbox, pipewire, state, options.pacing_period_ns, reset_owner!, phase)
        Bootstrap.cancelled(runtime) && break
        if !state.running || time_ns() < state.deadline_ns
            yield()
            GC.safepoint()
            continue
        end
        model_ns = model_nanoseconds(next_model_timestamp(science.driver))
        deadline = state.deadline_ns
        timing = exchange_timing(phase)
        sequence = timing === nothing ? exchange_frame!(pipewire, science.driver) :
            exchange_frame!(pipewire, science.driver; timing)
        # Public exchange returns only after the matching command is adopted.
        state.sequence = sequence
        model_time_sequence(science.driver) == sequence || error("model-time sequence differs from source")
        frame_timing = completed_frame_timing(frame_command_timing(pipewire))
        PupilOutput.sample!(pupil; generation=UInt64(state.generation), model_ns)
        OpticalObservation.sample!(observation, frame_timing, model_ns, time_ns())
        optical_finished = timing === nothing ? UInt64(0) : time_ns()
        state.deadline_ns = options.pacing_period_ns == 0 ? UInt64(0) :
            next_deadline(state.deadline_ns, options.pacing_period_ns, time_ns())
        timing === nothing || record_phase_timing!(phase, timing, frame_timing, deadline,
            optical_finished, state.deadline_ns)
        if options.total_exchanges !== nothing && sequence == options.total_exchanges
            state.running = false
            state.completed = true
            state.deadline_ns = 0
            save_phase_timing!(phase)
            save_report!(options, mailbox, state, Int64(frame_acquisition_generation(pipewire)))
        end
    end
    return nothing
end

command_mirror_properties(options, ::AbstractString, properties) = properties
function command_mirror_properties(options, names::NamedTuple, properties)
    return NamedTuple{keys(names)}(map(name ->
        PipeWireAORTC.InstrumentDefinition.mirror_properties(options, name), keys(names)))
end
function publish_mirror_properties!(stream, properties)
    isempty(properties) || update_properties!(stream, properties)
    return nothing
end
function publish_mirror_properties!(streams::NamedTuple, properties::NamedTuple)
    for name in keys(streams)
        publish_mirror_properties!(streams[name], properties[name])
    end
    return nothing
end

applied_command_names(name::AbstractString, enabled) = enabled ? "simulator-applied-command" : nothing
applied_command_names(names::NamedTuple, enabled) = enabled ? map(name -> name * "-applied", names) : nothing

function Owner.run_owner(options)
    runtime = options.bootstrap_runtime
    options.owner_check()
    println("SIMULATOR_PREPARING backend=$(options.backend) graph=$(options.graph)")
    flush(stdout)
    state = OwnerState()
    source_instance = Int64(rand(UInt64) % UInt64(typemax(Int64))) + Int64(1)
    observation = nothing
    pupil = nothing
    phase = nothing
    pipewire = nothing
    failures = Exception[]
    try
        options = merge(options, (;
            graph_sha256=options.graph === nothing ? nothing : PipeWireAORTC.Common.sha256_file(options.graph),
            configuration_sha256=PipeWireAORTC.Common.sha256_file(options.config_path)))
        phase = prepare_phase_timing(options)
        science = Owner.prepare_science(options; check=options.owner_check)
        pupil = PupilOutput.prepare(options, science)
        options = merge(options, (; pupil_output_status=() -> PupilOutput.status(pupil)))
        imaging = options.optical_observation ? OpticalObservation.owner_imaging_configuration(options) : OpticalObservation.default_imaging()
        observation = OpticalObservation.prepare(options.optical_observation ? science.definition : nothing, science.graph; imaging)
        options.owner_check()
        mailbox = prepare_source_control(options, state, source_instance)
        mirror_properties = PipeWireAORTC.InstrumentDefinition.mirror_properties(options)
        command_properties = command_mirror_properties(options, options.command_node, mirror_properties)
        pipewire = prepare_pipewire_hil(science.boundary, science.configuration;
            frame_buffers=options.detector_observation ? 3 : 2,
            command_buffers=options.command_observation ? 3 : 2,
            applied_command_node_name=applied_command_names(options.command_node, options.applied_command_observation),
            applied_command_buffers=3,
            applied_command_properties=merge(Dict("node.group" => "pipewireao-applied-observation",
                "node.sync-group" => "sync.pipewireao-applied-observation", "node.loop.name" => "telemetry-loop"),
                mirror_properties),
            image_sources=OpticalObservation.source_options(observation),
            frame_properties=merge(SourceControl.source_properties(mailbox), simulation_properties(options, science)),
            frame_params=mailbox.parameters.params,
            on_frame_param_changed=SourceControl.ParameterChanged(mailbox),
            frame_param_buffer=PodBuffer(4096),
            on_frame_param_overflow=SourceControl.ParameterOverflow(mailbox))
        with_thread_loop_lock(pipewire.loop) do _
            publish_mirror_properties!(pipewire.command_stream, command_properties)
        end
        with_applied_command_stream(pipewire) do streams
            publish_mirror_properties!(streams, command_properties)
        end
        pipewire_cpu = get(options, :pipewire_cpu, nothing)
        if pipewire_cpu !== nothing
            PipeWireAORTC.Placement.pin_loop!(pipewire.loop, pipewire_cpu; check=options.owner_check)
        end
        OpticalObservation.warm!(observation, pipewire; check=options.owner_check,
            cpu=get(options, :optical_diagnostics_cpu, nothing))
        PupilOutput.start!(pupil; remote=options.remote, cpu=get(options, :pupil_output_cpu, nothing),
            check=options.owner_check)
        precompile(OpticalObservation.close!, (typeof(observation), typeof(pipewire))) ||
            error("cannot compile prepared optical cleanup before admission")
        precompile(exchange_frame!, (typeof(pipewire), typeof(science.driver))) ||
            error("cannot compile prepared frame exchange before admission")
        if phase !== nothing
            precompile(Core.kwcall, (NamedTuple{(:timing,),Tuple{PipeWireExchangeTiming}},
                typeof(exchange_frame!), typeof(pipewire), typeof(science.driver))) ||
                error("cannot compile timed frame exchange before admission")
        end
        options.owner_check()
        Bootstrap.prepared!(runtime)
        println("SIMULATOR_PREPARED command_count=$(options.command_count) frame_shape=$(options.frame_shape)")
        flush(stdout)
        run_prepared!(options, science, pipewire, observation, mailbox, state, phase, pupil)
    catch error
        if !(error isa InterruptException && Bootstrap.clean_cancel(runtime))
            push!(failures, error)
            Bootstrap.fault!(runtime, error)
        end
    finally
        Bootstrap.finishing!(runtime)
        generation = state.generation
        if pipewire !== nothing
            try
                observed = Int64(frame_acquisition_generation(pipewire))
                if observed != state.generation
                    generation = nothing
                    push!(failures, ErrorException("source generation changed from $(state.generation) to $observed before its owner cursor committed"))
                end
            catch error
                generation = nothing
                push!(failures, error)
            end
        end
        try PupilOutput.close!(pupil) catch error; push!(failures, error) end
        try OpticalObservation.close!(observation, pipewire) catch error; push!(failures, error) end
        try save_phase_timing!(phase) catch error; push!(failures, error) end
        state.running = false
        state.deadline_ns = 0
        try Owner.write_report(options, state, generation, source_instance; failures) catch error; push!(failures, error) end
    end
    isempty(failures) || throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    return nothing
end

include("aos/external_pupil_owner.jl")

end
