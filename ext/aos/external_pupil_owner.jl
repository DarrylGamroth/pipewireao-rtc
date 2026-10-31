# Managed external-pupil optics use the ordinary AOS exposure owner and native
# bootstrap/source controls. No controller or mirror lives in this owner.
module ExternalPupilOwner
using ..PipeWireAORTCAOSExt: Owner, Bootstrap, SourceControl, Backends, target, OwnerState, execution_properties
using PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: external_pupil_contract, optical_execution_graph
using UUIDs, SHA
import PipeWireAORTC
const IC = PipeWireAORTC.InstrumentConfiguration

function pupil_contract(declaration, configured)
    optical = declaration.instrument.document["optical_input"]
    return external_pupil_contract(; pupil_resolution=configured["pupil_resolution"],
        diameter_m=optical["diameter_m"], plane=optical["plane"], curvature=optical["curvature"],
        registration=optical["registration"],
        wavelength_um=haskey(configured,"spectra") ? nothing : configured["wavelength_um"])
end

function spectral_properties(configured, name)
    spectrum = haskey(configured,"spectra") ? configured["spectra"][string(name)] :
        Dict("wavelength_um"=>configured["wavelength_um"], "fractional_bandwidth"=>0,
            "samples"=>1,"filter"=>"none")
    properties = Dict("optics.central-wavelength-m"=>string(spectrum["wavelength_um"]*1e-6),
        "optics.fractional-bandwidth"=>string(spectrum["fractional_bandwidth"]),
        "optics.spectral-samples"=>string(spectrum["samples"]), "optics.filter"=>string(spectrum["filter"]))
    spectrum["fractional_bandwidth"] == 0 &&
        (properties["optics.wavelength-m"] = string(spectrum["wavelength_um"]*1e-6))
    return properties
end

function optical_execution_properties(plant,name;prefix="optics.",unfringed=false)
    graph=optical_execution_graph(plant,name;unfringed)
    independent=unfringed ? getproperty(plant.observations,name).chopping.unfringed :
        getproperty(plant.graphs,name)
    properties=execution_properties(graph;prefix)
    if graph !== independent
        # Native properties are fixed at preparation. Describe both admitted
        # executions; their node counts are not a per-frame selection report.
        properties[prefix*"execution-scope"]="prepared"
        merge!(properties,execution_properties(independent;prefix=prefix*"independent."))
    end
    return properties
end

function sensor_contract(declaration, configured, plant, name, identity)
    graph = getproperty(plant.graphs, name)
    observation = getproperty(plant.observations, name)
    sampling = optical_sampling_m(AlgorithmGraphs.prepared_graph_node(graph, observation.sampling_node))
    response = get(observation, :response, nothing)
    image = response === nothing ? graph_output(graph, observation.output) :
        graph_output(response.graph, response.output)
    schema = response === nothing ? "org.adaptiveopticssim.optical-intensity/sha256-" *
        bytes2hex(sha256(join((identity, name, sampling, size(image)), "\n"))) * "/1" : response.frame_schema
    path = declaration.instrument.document["optical_paths"][string(name)]
    sensor = declaration.instrument.document["wavefront_sensors"][path["sensor"]]
    haskey(sensor,"detector_shape") && Tuple(sensor["detector_shape"]) != size(image) &&
        throw(DimensionMismatch("sensor detector_shape differs from its optical product"))
    get(sensor,"expected_schema",schema) == schema || throw(ArgumentError("sensor expected_schema differs from its optical product"))
    execution = optical_execution_properties(plant,name)
    response === nothing || merge!(execution, execution_properties(response.graph; prefix="detector."))
    if response !== nothing
        acquisition = get(sensor, "acquisition", Dict())
        execution["detector.roi-origin-known"] = string(haskey(acquisition, "roi_origin"))
        execution["detector.roi-shape"] = join(size(image), ",")
        if haskey(acquisition, "roi_origin")
            execution["detector.roi-origin"] = join(acquisition["roi_origin"], ",")
        end
    end
    if hasproperty(observation, :chopping)
        merge!(execution, optical_execution_properties(plant,name;unfringed=true,prefix="optics.unfringed."))
    end
    return (; image, schema, properties=merge(spectral_properties(configured,name), execution,
        Dict("optics.model-sha256"=>String(chopprefix(identity,"sha256:")),
            "optics.branch"=>string(name), "optics.sampling-m"=>string(sampling),
            "optics.axis-order"=>"y,x", "optics.pts-units"=>"simulation_nanoseconds",
            "optics.exposure-duration-ns"=>string(getproperty(plant.exposures,name).duration_ns),
            "optics.units"=>response === nothing ? "relative_intensity" : "declared_detector_output",
            "detector.name"=>sensor["detector"]["name"])))
end

function prepare(path; settings=NamedTuple(), target=Backends.HostComputeDevice(),
        chopping=NamedTuple(), check=()->nothing)
    declaration = IC.load_simulation(path)
    if get(get(declaration.document,"optical_model",Dict()),"format",nothing) == "zemax"
        AdaptiveOpticsSim.Optics.Zemax.validate_provenance(declaration.directory)
    end
    configured = IC.settings(declaration,settings)
    identity = IC.prescription_identity(declaration,configured)
    check()
    plant = IC.prepare_external_pupil(path; settings, target, chopping)
    # Establish immutable optical sampling without consuming detector draws.
    foreach(step_graph!, values(plant.graphs))
    sensors = map(keys(plant.graphs)) do name
        sensor_contract(declaration,configured,plant,name,identity)
    end
    reset_external_pupil!(plant)
    check()
    return (; plant, declaration, configured, identity, chopping, pupil=pupil_contract(declaration,configured),
        sensors=NamedTuple{keys(plant.graphs)}(sensors))
end

function stream_options(science, pupil_node, sensor_nodes; sensor_buffers=2, input_option=nothing)
    pupil = input_option === nothing ? PipeWireArrayStreamOptions(; node_name=pupil_node, media_name="External pupil field",
        schema=science.pupil.schema, format=NdArrayFormat(NdArray.F32_LE,science.pupil.shape;layout=NdArray.ROW_MAJOR),
        properties=science.pupil.properties) : input_option
    sensors = map(keys(science.sensors)) do name
        sensor = getproperty(science.sensors,name)
        chopped = hasproperty(science.chopping, name)
        duration = getproperty(science.plant.exposures,name).duration_ns
        duration > 0 || throw(ArgumentError("sensor exposure duration must be positive"))
        rate = 1_000_000_000 // duration
        PipeWireArrayStreamOptions(; node_name=getproperty(sensor_nodes,name), media_name=string(name),
            buffers=sensor_buffers, acquisition_version=chopped ? 3 : 2,
            schema=sensor.schema, format=NdArrayFormat(NdArray.F32_LE,size(sensor.image);layout=NdArray.ROW_MAJOR,
                rate=SPA.Fraction(numerator(rate),denominator(rate))),
            properties=sensor.properties)
    end
    return (pupil,sensors...)
end

"Adapt the public transport receipt without changing physical axes or units."
function feed!(emit, plant, packet::Array{Float32,3}, receipt)
    size(packet)==(2,size(plant.pupil_opd)...) || throw(DimensionMismatch("external pupil packet shape"))
    identity = receipt.identity
    return step_external_pupil!(emit,plant,view(packet,1,:,:),view(packet,2,:,:),
        ModelTimestamp(receipt.pts),ModelDuration(receipt.duration);
        domain=identity.domain.bytes,generation=identity.generation,sequence=identity.sequence,
        lost_samples=receipt.lost_samples)
end

# Runtime startup exercises the same feed and emitter as acquisition. Publication
# remains disabled until all synthetic optical/response history has been reset.
# Detector graph reset restores its construction RNG seed (Host or counter RNG).
function warmup!(emit, science, packet, frames, buffers; check=()->nothing)
    durations = map(exposure->exposure.duration_ns, values(science.plant.exposures))
    step = reduce(gcd, durations)
    horizon = Base.checked_mul(maximum(durations), Int64(2))
    samples = div(horizon, step)
    0 < samples <= 4096 || throw(ArgumentError("external-pupil warmup exceeds 4096 samples"))
    try
        fill!(packet, 0)
        view(packet, 2, :, :) .= 1f0
        # Local receipt only, matching live feed specialization. Its isolated
        # identity never reaches transport or changes the live owner identity.
        identity_domain = AcquisitionDomain(ntuple(index->UInt8(index), 16))
        for sequence in 1:samples
            check()
            receipt = PipeWireArrayReceipt(Int64((sequence-1)*step), UInt64(step),
                AcquisitionIdentity(identity_domain, UInt64(1), UInt64(sequence)), UInt64(0))
            feed!(emit, science.plant, packet, receipt) || error("external-pupil warmup sample rejected")
        end
    finally
        reset_external_pupil!(science.plant)
        fill!(packet, 0)
        foreach(frame->fill!(frame, 0), frames)
        foreach(buffer->fill!(buffer, 0), buffers)
    end
    return nothing
end

include("clocked_optical_source.jl")

function Owner.prepare_external_pupil_science(options; check=()->nothing)
    check()
    science = prepare(options.plant.definition; settings=options.plant.settings,
        chopping=options.plant.chopping, target=target(options), check)
    return options.version == 6 ? prepare_clocked_source(options,science;check) : science
end

function PipeWireAORTC.InstrumentExport.external_pupil_port_contracts(path; settings=NamedTuple(), chopping=NamedTuple())
    science = prepare(path; settings, chopping)
    contract(format, schema) = Dict("shape"=>collect(format), "element-type"=>"F32_LE", "schema"=>schema)
    return Dict("pupil"=>contract(science.pupil.shape,science.pupil.schema),
        "sensors"=>Dict(string(name)=>contract(size(sensor.image),sensor.schema)
            for (name,sensor) in pairs(science.sensors)))
end

function trigger_state(science, name, metadata)
    hasproperty(science.chopping, name) || return ACQUISITION_TRIGGER_ABSENT
    kind = get(metadata, :chopped_image_kind, nothing)
    kind === :mixed && return ACQUISITION_TRIGGER_MIXED
    kind in (:fringed, :unfringed) || throw(ArgumentError("chopped exposure lacks its actual optical phase"))
    high = (kind === :fringed) == getproperty(science.chopping, name).trigger_high_is_fringed
    return high ? ACQUISITION_TRIGGER_HIGH : ACQUISITION_TRIGGER_LOW
end

function sensor_sequence(metadata, chopped::Bool)
    chopped || return metadata.sequence
    # AOS complete exposures occupy aligned windows of its zero-origin model
    # clock. The wire identity records the observed window ordinal so missing
    # whole windows cannot appear adjacent. Optical phase is never inferred here.
    pts, duration = metadata.pts, metadata.duration
    pts isa Int64 && pts >= 0 && duration isa UInt64 && 0 < duration <= typemax(Int64) &&
        UInt64(pts) % duration == 0 || throw(ArgumentError("chopped exposure must occupy an aligned nonnegative model-time window"))
    return Base.checked_add(div(UInt64(pts), duration), UInt64(1))
end

function domain()
    value = uuid4().value
    return AcquisitionDomain(ntuple(i->UInt8((value >> (8(i-1))) & 0xff),16))
end

function report!(options, mailbox, state)
    Owner.write_report(options,state,state.generation,mailbox.instance)
    SourceControl.report_ready!(mailbox,state.generation,state.sequence)
    return nothing
end

function consume_control!(options, mailbox, filter, state, reset_owner!)
    mailbox.ready[] || return nothing
    loop = options.bootstrap_runtime.transport.loop
    kind,token,running = with_thread_loop_lock(loop) do _
        SourceControl.pending(mailbox)
    end
    if kind != SourceControl.INITIAL
        result = SourceControl.apply!(state,kind,token,running,time_ns(),UInt64(1),reset_owner!)
        kind == SourceControl.RESET && result == 0 && report!(options,mailbox,state)
        with_thread_loop_lock(loop) do _
            SourceControl.publish!(mailbox,filter,kind,token,result,state,state.generation)
        end
    end
    with_thread_loop_lock(loop) do _
        SourceControl.publish_rejection!(mailbox,filter,state,state.generation)
    end
    return nothing
end

function publish_sensor!(owner,index,buffer,identity,pts,duration,classification)
    if stage_pipewire_array!(owner,index,buffer;identity,pts,duration,trigger_state=classification)
        with_array_stream(trigger_process!,owner,index)
    end
    return nothing
end

function stream_execution(options,science,state)
    names = keys(science.sensors)
    clocked = options.version == 6
    packet = zeros(Float32,science.pupil.shape)
    command = clocked ? zeros(Float32,options.command_count) : Float32[]
    incoming_command = similar(command)
    frames = map(sensor->zeros(eltype(sensor.image),size(sensor.image)),values(science.sensors))
    # Always own the host copy of borrowed optical products. Float32 frames
    # already satisfy the transport type and need no conversion storage.
    buffers = map(frame->eltype(frame) === Float32 ? frame : zeros(Float32,size(frame)),frames)
    domains = map(_->domain(),names)
    publication_enabled = Ref(false)
    transport_owner = Ref{Any}(nothing)
    chopping = science.chopping
    emit = function (name,image,metadata)
        index = findfirst(==(name),names)
        copyto!(frames[index],image)
        if buffers[index] !== frames[index]
            buffers[index] .= frames[index]
        end
        all(isfinite,buffers[index]) || throw(ArgumentError("optical product exceeds Float32 transport range"))
        sequence = sensor_sequence(metadata, hasproperty(chopping, name))
        classification = trigger_state((;chopping), name, metadata)
        if publication_enabled[]
            identity = AcquisitionIdentity(domains[index],UInt64(state.generation),sequence)
            publish_sensor!(transport_owner[],index+1,buffers[index],identity,
                metadata.pts,metadata.duration,classification)
        end
        return nothing
    end
    return (;packet,command,incoming_command,frames,buffers,domains,publication_enabled,
        transport_owner,emit)
end

# Compile the concrete transport calls without staging synthetic camera frames.
function warmup_stream_transport!(owner,execution,clocked)
    input = clocked ? execution.incoming_command : execution.packet
    precompile(drain_pipewire_array!, (typeof(input),typeof(owner),Int)) ||
        error("external-pupil input transport preparation failed")
    for buffer in execution.buffers
        precompile(publish_sensor!, (typeof(owner),Int,typeof(buffer),AcquisitionIdentity,
            Int64,UInt64,typeof(ACQUISITION_TRIGGER_ABSENT))) ||
            error("external-pupil output transport preparation failed")
    end
    return nothing
end

Base.@nospecializeinfer function run_streams!(@nospecialize(options), science, mailbox, state,
        execution, @nospecialize(owner), @nospecialize(ticket))
    @info "Optical owner startup" phase=:streams_entry at_ns=time_ns()
    runtime = options.bootstrap_runtime
    transport = runtime.transport
    clocked = options.version == 6
    (;packet,command,incoming_command,emit,publication_enabled,transport_owner) = execution
    transport_owner[] = owner
    filter = nothing
    try
        with_thread_loop_lock(transport.loop) do _
            filter = Filter(transport.core,options.control_node;
                properties=merge(SourceControl.source_properties(mailbox),
                    optical_execution_properties(science.plant,first(keys(science.plant.graphs));prefix="aos.simulation."),Dict(
                    "node.name"=>options.control_node,"media.class"=>"Control",
                    "aos.simulation.mode"=>clocked ? "clocked-optical" : "external-pupil", "aos.simulation.backend"=>string(options.backend),
                    "aos.simulation.device"=>string(options.device),
                    "aos.simulation.calibration-identity"=>options.calibration_identity,
                    "aos.simulation.configuration-sha256"=>options.configuration_sha256,
                    "aos.simulation.prescription-identity"=>science.identity)),
                on_param_changed=SourceControl.ParameterChanged(mailbox))
            connect!(filter;flags=FILTER_ASYNC|FILTER_INACTIVE,params=mailbox.parameters.params)
        end
        while true
            Bootstrap.check_connect!(runtime,ticket)
            ready = with_thread_loop_lock(transport.loop) do _
                node_id(filter) ∉ (UInt32(0),typemax(UInt32))
            end
            ready &= all(eachindex(owner.streams)) do index
                with_array_stream(owner,index) do stream
                    node_id(stream) ∉ (UInt32(0),typemax(UInt32)) && stream_state(stream) in
                        (PipeWireAO.LibPipeWire.PW_STREAM_STATE_PAUSED,PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING)
                end
            end
            ready && break
            sleep(0.001)
        end
        @info "Optical owner startup" phase=:streams_ready at_ns=time_ns()
        @info "Optical owner startup" phase=:transport_warmup_begin at_ns=time_ns()
        warmup_stream_transport!(owner,execution,clocked)
        Bootstrap.check_connect!(runtime,ticket)
        @info "Optical owner startup" phase=:transport_warmup_end at_ns=time_ns()
        publication_enabled[] = true
        Bootstrap.connected!(runtime,ticket)
        Bootstrap.await_connected!(runtime,ticket)
        upstream_generation = UInt64(0)
        reset_owner! = () -> begin
            state.generation = Base.checked_add(state.generation,Int64(1))
            reset_external_pupil!(science.plant)
            if clocked
                reset_clocked_source!(science)
                fill!(command,0)
                fill!(incoming_command,0)
                state.sequence = 0
                state.deadline_ns = 0
            end
            for index in eachindex(owner.streams)
                reset_pipewire_array!(owner,index)
            end
            upstream_generation = UInt64(0)
        end
        while !Bootstrap.cancelled(runtime)
            consume_control!(options,mailbox,filter,state,reset_owner!)
            Bootstrap.cancelled(runtime) && break
            all(index->!array_stream_status(owner,index).failed,eachindex(owner.streams)) ||
                error("external-pupil array transport failed")
            if clocked
                receipt = drain_pipewire_array!(incoming_command,owner,1)
                if receipt !== nothing
                    all(isfinite,incoming_command) && maximum(abs,incoming_command) <= options.command_limit ||
                        throw(ArgumentError("native optical command exceeds its declared finite amplitude domain"))
                    copyto!(command,incoming_command)
                end
                if !state.running || time_ns() < state.deadline_ns
                    sleep(0.001)
                    continue
                end
                state.sequence = step_clocked_source!(emit,science,command;generation=UInt64(state.generation))
                state.deadline_ns = options.pacing_period_ns == 0 ? UInt64(0) : time_ns()+options.pacing_period_ns
                continue
            end
            receipt = drain_pipewire_array!(packet,owner,1)
            if receipt === nothing || !state.running
                sleep(0.001)
                continue
            end
            if upstream_generation != 0 && upstream_generation != receipt.identity.generation
                state.generation = Base.checked_add(state.generation,Int64(1))
            end
            upstream_generation = receipt.identity.generation
            accepted = feed!(emit,science.plant,packet,receipt)
            accepted && (state.sequence = Base.checked_add(state.sequence,UInt64(1)))
        end
    finally
        Bootstrap.finishing!(runtime)
        with_thread_loop_lock(transport.loop) do _
            filter === nothing || close(filter)
        end
    end
    return nothing
end

# Model warming belongs to Preparing. The same quiet emitter checks conversion,
# sequence and chopping contracts here and later publishes real camera frames.
# Its transport reference remains empty until Connect; no warmup frame escapes.
function prepare_stream_execution!(options,science,mailbox,state)
    options.owner_check()
    execution = stream_execution(options,science,state)
    @info "Optical owner startup" phase=:warmup_begin at_ns=time_ns()
    try
        if options.version == 6
            warmup_clocked_source!(execution.emit,science,execution.command;check=options.owner_check)
        else
            warmup!(execution.emit,science,execution.packet,execution.frames,execution.buffers;
                check=options.owner_check)
        end
    finally
        fill!(execution.packet,0)
        fill!(execution.command,0)
        fill!(execution.incoming_command,0)
        foreach(frame->fill!(frame,0),execution.frames)
        foreach(buffer->fill!(buffer,0),execution.buffers)
    end
    @info "Optical owner startup" phase=:warmup_end at_ns=time_ns()
    options.owner_check()
    @info "Optical owner startup" phase=:precompile_begin at_ns=time_ns()
    ready = precompile(run_streams!, (Any,typeof(science),typeof(mailbox),
        typeof(state),typeof(execution),Any,Any))
    @info "Optical owner startup" phase=:precompile_end at_ns=time_ns()
    options.owner_check()
    ready || error("external-pupil control-loop preparation failed")
    return execution
end

function Owner.run_external_pupil_owner(options)
    runtime = options.bootstrap_runtime
    options = merge(options,(;configuration_sha256=PipeWireAORTC.Common.sha256_file(options.config_path)))
    state = OwnerState()
    mailbox = SourceControl.Mailbox(Int64(rand(UInt64)%UInt64(typemax(Int64)))+Int64(1))
    failures = Exception[]
    try
        science = Owner.prepare_external_pupil_science(options;check=options.owner_check)
        report!(options,mailbox,state)
        streams = stream_options(science,options.pupil_node,options.sensor_nodes;sensor_buffers=options.sensor_buffers,
            input_option=options.version == 6 ? clocked_command_option(options) : nothing)
        execution = prepare_stream_execution!(options,science,mailbox,state)
        @info "Optical owner startup" phase=:prepared at_ns=time_ns()
        Bootstrap.prepared!(runtime)
        ticket = Bootstrap.take_connect!(runtime)
        @info "Optical owner startup" phase=:connect_received at_ns=time_ns()
        Bootstrap.check_connect!(runtime,ticket)
        with_array_streams(streams;remote=options.remote,input=(true,map(_->false,keys(science.sensors))...)) do owner
            @info "Optical owner startup" phase=:streams_constructed at_ns=time_ns()
            cpu = get(options,:pipewire_cpu,nothing)
            cpu === nothing || PipeWireAORTC.Placement.pin_loop!(owner.loop,cpu;check=options.owner_check)
            run_streams!(options,science,mailbox,state,execution,owner,ticket)
        end
    catch error
        if !(error isa InterruptException && Bootstrap.clean_cancel(runtime))
            @error "Optical owner failed" exception=(error,catch_backtrace())
            push!(failures,error)
            Bootstrap.fault!(runtime,error)
        end
    finally
        Bootstrap.finishing!(runtime)
        state.running = false
        try Owner.write_report(options,state,state.generation,mailbox.instance;failures) catch error; push!(failures,error) end
    end
    isempty(failures) || throw(length(failures)==1 ? only(failures) : CompositeException(failures))
    return nothing
end
end
