const Instruments = PipeWireAORTC.InstrumentConfiguration

"Prepare an ordinary typed AOS graph from an instrument's SPA-JSON declaration."
function Instruments.prepare_system(path::AbstractString;settings=NamedTuple(),calibration=false,
        target=Backends.HostComputeDevice(),execution=StreamGraphExecution())
    declaration = Instruments.load(path)
    configured = Instruments.settings(declaration,settings)
    document = Instruments.graph_document(declaration,configured;calibration)
    names = String[]
    for (section,field) in (("inputs","binding"),("parameters","binding"),("delayed_links","initial"))
        for entry in get(document,section,[])
            push!(names,entry[field])
        end
    end
    unique!(names)
    specs = declaration.document["bindings"]
    all(name->haskey(specs,name),names) || throw(ArgumentError("instrument graph names an undeclared array binding"))
    retained = Ref(0)
    arrays = Tuple(map(names) do name
        source = Instruments.binding_values(declaration,configured,specs[name])
        retained[] += sizeof(eltype(source))*length(source)
        retained[] <= Owner.MAX_RETAINED_BYTES || throw(ArgumentError("instrument bindings exceed 512 MiB"))
        copy_to_target(target,source)
    end)
    bindings = NamedTuple{Tuple(Symbol.(names))}(arrays)
    definition = load_algorithm_graph(document;bindings)
    graph = prepare_algorithm_graph(definition;target,execution)
    hil = declaration.document["hil"]
    Instruments.fields(hil,("command_input","frame_output"),("command_input","frame_output"),"instrument HIL boundary")
    boundary = prepare_graph_hil_boundary(graph;
        command_input=Symbol(hil["command_input"]),frame_output=Symbol(hil["frame_output"]))
    frame_period_s = Float32(declaration.document["frame_period_s"])
    isfinite(frame_period_s) && frame_period_s>0 || throw(ArgumentError("invalid instrument frame period"))
    period_ns = round(UInt64,Float64(frame_period_s)*1e9)
    driver = FixedStepModelTimeDriver(PeriodicSchedule(;period_ns))
    mirror_names = Tuple(Symbol.(collect(keys(declaration.document["deformable_mirrors"]))))
    mirror_descriptions = NamedTuple{mirror_names}(Tuple(
        Instruments.mirror(declaration,configured,name).description
        for name in keys(declaration.document["deformable_mirrors"])))
    return (;definition,graph,boundary,target,frame_period_s,driver,mirror_descriptions,
        settings=Instruments._instrument_seal(configured))
end

function prepare_configured_science(options,device;check=()->nothing)
    execution = options.backend===:cpu ? StreamGraphExecution() : CapturedGraphExecution()
    system = Instruments.prepare_system(options.plant.definition;
        settings=options.plant.settings,target=device,execution)
    check()
    AdaptiveOpticsSimPipeWireHIL.validate_hil_system(system;
        command_input=options.command_input,frame_output=options.frame_output,
        command_shape=(options.command_count,),frame_shape=options.frame_shape)
    declaration = Instruments.load(options.plant.definition)
    contracts = Tuple((;frame_encoding=Symbol(entry["frame_encoding"]),
        frame_schema=entry["frame_schema"],command_schema=entry["command_schema"],
        command_scale=Float32(entry["command_scale"])) for entry in declaration.document["wire_contracts"])
    AdaptiveOpticsSimPipeWireHIL.validate_wire_contract(options.frame_encoding,
        options.frame_schema,options.command_schema,options.command_scale,contracts)
    configuration = wire_configuration(options)
    validate_configuration(configuration,options)
    round(UInt64,Float64(system.frame_period_s)*1e9)==options.period_ns ||
        throw(ArgumentError("instrument cadence differs from the application"))
    # Validate actual node timing, independently of declaration metadata.
    for node in system.definition.nodes
        validate_node_timing(node.config,options)
    end
    return (;system.definition,system.graph,system.boundary,target=device,artifacts=(),configuration)
end

validate_node_timing(config,options) = nothing
function validate_node_timing(config::AlgorithmGraphs.MultiLayerAtmosphereOPDNodeConfig,options)
    round(UInt64,Float64(config.atmosphere_step)*1e9)==options.period_ns ||
        throw(ArgumentError("atmosphere step differs from configured cadence"))
end
function validate_node_timing(config::AlgorithmGraphs.CMOSDetectorAcquisitionNodeConfig,options)
    round(UInt64,Float64(config.exposure_duration_s)*1e9)==options.exposure_ns ||
        throw(ArgumentError("detector exposure differs from configured acquisition"))
end
