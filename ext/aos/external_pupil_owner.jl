# Managed external-pupil optics use the ordinary AOS exposure owner and native
# bootstrap/source controls. No controller or mirror lives in this owner.
module ExternalPupilOwner
using ..PipeWireAORTCAOSExt: Owner, Bootstrap, SourceControl, Backends, target, OwnerState
using PipeWireAO, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL
using AdaptiveOpticsSim.AlgorithmGraphs
using AdaptiveOpticsSim.AlgorithmGraphs: external_pupil_contract
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
    return (; image, schema, properties=merge(spectral_properties(configured,name),
        Dict("optics.model-sha256"=>String(chopprefix(identity,"sha256:")),
            "optics.branch"=>string(name), "optics.sampling-m"=>string(sampling),
            "optics.axis-order"=>"y,x", "optics.pts-units"=>"simulation_nanoseconds",
            "optics.exposure-duration-ns"=>string(getproperty(plant.exposures,name).duration_ns),
            "optics.units"=>response === nothing ? "relative_intensity" : "declared_detector_output",
            "detector.name"=>sensor["detector"]["name"])))
end

function prepare(path; settings=NamedTuple(), target=Backends.HostComputeDevice(), check=()->nothing)
    declaration = IC.load_simulation(path)
    if get(get(declaration.document,"optical_model",Dict()),"format",nothing) == "zemax"
        AdaptiveOpticsSim.Optics.Zemax.validate_provenance(declaration.directory)
    end
    configured = IC.settings(declaration,settings)
    identity = IC.prescription_identity(declaration,configured)
    check()
    plant = IC.prepare_external_pupil(path; settings, target, execution=StreamGraphExecution())
    # Establish immutable optical sampling without consuming detector draws.
    foreach(step_graph!, values(plant.graphs))
    sensors = map(keys(plant.graphs)) do name
        sensor_contract(declaration,configured,plant,name,identity)
    end
    reset_external_pupil!(plant)
    check()
    return (; plant, declaration, configured, identity, pupil=pupil_contract(declaration,configured),
        sensors=NamedTuple{keys(plant.graphs)}(sensors))
end

function stream_options(science, pupil_node, sensor_nodes)
    pupil = PipeWireArrayStreamOptions(; node_name=pupil_node, media_name="External pupil field",
        schema=science.pupil.schema, format=NdArrayFormat(NdArray.F32_LE,science.pupil.shape;layout=NdArray.ROW_MAJOR),
        properties=science.pupil.properties)
    sensors = map(keys(science.sensors)) do name
        sensor = getproperty(science.sensors,name)
        PipeWireArrayStreamOptions(; node_name=getproperty(sensor_nodes,name), media_name=string(name),
            schema=sensor.schema, format=NdArrayFormat(NdArray.F32_LE,size(sensor.image);layout=NdArray.ROW_MAJOR),
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

function Owner.prepare_external_pupil_science(options; check=()->nothing)
    check()
    return prepare(options.plant.definition; settings=options.plant.settings, target=target(options), check)
end

function PipeWireAORTC.InstrumentExport.external_pupil_port_contracts(path; settings=NamedTuple())
    science = prepare(path; settings)
    contract(format, schema) = Dict("shape"=>collect(format), "element-type"=>"F32_LE", "schema"=>schema)
    return Dict("pupil"=>contract(science.pupil.shape,science.pupil.schema),
        "sensors"=>Dict(string(name)=>contract(size(sensor.image),sensor.schema)
            for (name,sensor) in pairs(science.sensors)))
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

function run_streams!(options, science, mailbox, state, owner, ticket)
    runtime = options.bootstrap_runtime
    transport = runtime.transport
    names = keys(science.sensors)
    packet = zeros(Float32,science.pupil.shape)
    frames = map(sensor->zeros(eltype(sensor.image),size(sensor.image)),values(science.sensors))
    buffers = map(sensor->zeros(Float32,size(sensor.image)),values(science.sensors))
    domains = map(_->domain(),names)
    filter = nothing
    try
        with_thread_loop_lock(transport.loop) do _
            filter = Filter(transport.core,options.control_node;
                properties=merge(SourceControl.source_properties(mailbox),Dict(
                    "node.name"=>options.control_node,"media.class"=>"Control",
                    "aos.simulation.mode"=>"external-pupil", "aos.simulation.backend"=>string(options.backend),
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
        Bootstrap.connected!(runtime,ticket)
        Bootstrap.await_connected!(runtime,ticket)
        upstream_generation = UInt64(0)
        reset_owner! = () -> begin
            state.generation = Base.checked_add(state.generation,Int64(1))
            reset_external_pupil!(science.plant)
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
            receipt = drain_pipewire_array!(packet,owner,1)
            if receipt === nothing || !state.running
                sleep(0.001)
                continue
            end
            if upstream_generation != 0 && upstream_generation != receipt.identity.generation
                state.generation = Base.checked_add(state.generation,Int64(1))
            end
            upstream_generation = receipt.identity.generation
            accepted = feed!(science.plant,packet,receipt) do name,image,metadata
                index = findfirst(==(name),names)
                copyto!(frames[index],image)
                buffers[index] .= frames[index]
                all(isfinite,buffers[index]) || throw(ArgumentError("optical product exceeds Float32 transport range"))
                identity = AcquisitionIdentity(domains[index],UInt64(state.generation),metadata.sequence)
                if stage_pipewire_array!(owner,index+1,buffers[index];identity,pts=metadata.pts,duration=metadata.duration)
                    with_array_stream(trigger_process!,owner,index+1)
                end
            end
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

function Owner.run_external_pupil_owner(options)
    runtime = options.bootstrap_runtime
    options = merge(options,(;configuration_sha256=PipeWireAORTC.Common.sha256_file(options.config_path)))
    state = OwnerState()
    mailbox = SourceControl.Mailbox(Int64(rand(UInt64)%UInt64(typemax(Int64)))+Int64(1))
    failures = Exception[]
    try
        science = Owner.prepare_external_pupil_science(options;check=options.owner_check)
        report!(options,mailbox,state)
        streams = stream_options(science,options.pupil_node,options.sensor_nodes)
        Bootstrap.prepared!(runtime)
        ticket = Bootstrap.take_connect!(runtime)
        Bootstrap.check_connect!(runtime,ticket)
        with_array_streams(streams;remote=options.remote,input=(true,map(_->false,keys(science.sensors))...)) do owner
            cpu = get(options,:pipewire_cpu,nothing)
            cpu === nothing || PipeWireAORTC.Placement.pin_loop!(owner.loop,cpu;check=options.owner_check)
            run_streams!(options,science,mailbox,state,owner,ticket)
        end
    catch error
        if !(error isa InterruptException && Bootstrap.clean_cancel(runtime))
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
