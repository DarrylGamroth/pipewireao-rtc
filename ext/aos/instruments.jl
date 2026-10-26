const Instruments = PipeWireAORTC.InstrumentConfiguration

function PipeWireAORTC.InstrumentExport.simulator_port_contracts(path::AbstractString;
        settings=Dict())
    declaration = Instruments.load_simulation(path)
    configured = Instruments.settings(declaration, settings)
    document = Instruments.graph_document(declaration, configured)
    # Public AOS factories return cold typed declarations. They do not prepare
    # numerical state or require any input/parameter artifact arrays.
    factories = configured_graph_node_types()
    nodes = Tuple(map(document["nodes"]) do entry
        factory = getproperty(factories, Symbol(entry["type"]))
        factory(Symbol(entry["name"]), Instruments._instrument_seal(entry["config"]),
            Instruments._instrument_seal(get(entry, "props", Dict())))
    end)
    atmosphere = any(entry -> entry["name"] == "atmosphere_opd", get(document, "outputs", []))
    return OpticalObservation.port_contracts(nodes; atmosphere)
end

"Prepare an ordinary typed AOS graph from an instrument's SPA-JSON declaration."
function Instruments.prepare_system(path::AbstractString;settings=NamedTuple(),calibration=false,
        target=Backends.HostComputeDevice(),execution=StreamGraphExecution())
    declaration = Instruments.load_simulation(path)
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
    definition = load_algorithm_graph(document;bindings,node_types=configured_graph_node_types())
    for node in definition.nodes
        validate_sample_period(node.config, declaration.document["frame_period_s"])
    end
    graph = prepare_algorithm_graph(definition;target,execution)
    hil = declaration.document["hil"]
    Instruments.fields(hil,("command_input","frame_output"),("command_input","frame_output"),"instrument HIL boundary")
    boundary = prepare_graph_hil_boundary(graph;
        command_input=configured_command_inputs(hil["command_input"]),frame_output=Symbol(hil["frame_output"]))
    frame_period_s = Float32(declaration.document["frame_period_s"])
    isfinite(frame_period_s) && frame_period_s>0 || throw(ArgumentError("invalid instrument frame period"))
    period_ns = round(UInt64,Float64(frame_period_s)*1e9)
    driver = FixedStepModelTimeDriver(PeriodicSchedule(;period_ns))
    mirror_names = Tuple(Symbol.(collect(keys(declaration.instrument.document["deformable_mirrors"]))))
    mirror_descriptions = NamedTuple{mirror_names}(Tuple(
        Instruments.mirror(declaration,configured,name).description
        for name in keys(declaration.instrument.document["deformable_mirrors"])))
    return (;definition,graph,boundary,target,frame_period_s,driver,mirror_descriptions,
        settings=Instruments._instrument_seal(configured))
end

configured_command_inputs(value::AbstractString) = Symbol(value)
configured_command_inputs(value::AbstractVector) = Tuple(Symbol.(value))

function prepare_configured_science(options,device;check=()->nothing)
    execution = options.backend===:cpu ? StreamGraphExecution() : CapturedGraphExecution()
    system = Instruments.prepare_system(options.plant.definition;
        settings=options.plant.settings,target=device,execution)
    check()
    AdaptiveOpticsSimPipeWireHIL.validate_hil_system(system;
        command_input=options.command_input,frame_output=options.frame_output,
        command_shape=Owner.command_shapes(options.command_count),frame_shape=options.frame_shape)
    declaration = Instruments.load_simulation(options.plant.definition)
    contracts = Tuple((;frame_encoding=Symbol(entry["frame_encoding"]),
        frame_schema=entry["frame_schema"],command_schema=Instruments._instrument_seal(entry["command_schema"]),
        command_scale=configured_command_scales(Instruments._instrument_seal(entry["command_scale"]))) for entry in declaration.document["wire_contracts"])
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

configured_command_scales(value::Real) = Float32(value)
configured_command_scales(values::NamedTuple) = map(Float32,values)

validate_node_timing(config,options) = nothing
validate_sample_period(config, period) = nothing
if isdefined(AlgorithmGraphs, :SecondOrderResponseNodeConfig)
    function validate_sample_period(config::AlgorithmGraphs.SecondOrderResponseNodeConfig, period)
        config.sample_period_s == period ||
            throw(ArgumentError("response sample period differs from the simulation frame period"))
        return nothing
    end
    function validate_node_timing(config::AlgorithmGraphs.SecondOrderResponseNodeConfig,options)
        round(UInt64,config.sample_period_s*1e9)==options.period_ns ||
            throw(ArgumentError("response sample period differs from configured cadence"))
        return nothing
    end
end
function validate_node_timing(config::AlgorithmGraphs.MultiLayerAtmosphereOPDNodeConfig,options)
    round(UInt64,Float64(config.atmosphere_step)*1e9)==options.period_ns ||
        throw(ArgumentError("atmosphere step differs from configured cadence"))
end
function validate_node_timing(config::AlgorithmGraphs.CMOSDetectorAcquisitionNodeConfig,options)
    round(UInt64,Float64(config.exposure_duration_s)*1e9)==options.exposure_ns ||
        throw(ArgumentError("detector exposure differs from configured acquisition"))
end
function validate_node_timing(config::AlgorithmGraphs.EMCCDDetectorAcquisitionNodeConfig,options)
    round(UInt64,Float64(config.exposure_duration_s)*1e9)==options.exposure_ns ||
        throw(ArgumentError("detector exposure differs from configured acquisition"))
end

# These cold bindings reuse AOS's telescope definition, including its aperture
# convention. The coefficients of the coordinate basis are metres of OPD;
# neither a physical stage angle nor a mirror reflection factor is inferred.
function pupil_binding_resolution(declaration, configured, binding)
    value = Instruments.Common.configuration_value(binding["resolution"],
        Instruments.configuration_context(declaration, configured))
    resolution = Instruments.dimension(configured, value)
    Instruments.Artifacts.checked_shape((resolution, resolution, 2), sizeof(Float32))
    return Int(resolution)
end

function configured_telescope(declaration, configured, binding)
    resolution = pupil_binding_resolution(declaration, configured, binding)
    spec = declaration.instrument.document["telescope"]
    return AdaptiveOpticsSim.Optics.prepare_telescope(
        AdaptiveOpticsSim.Optics.TelescopeDefinition(;
            resolution, diameter=spec["telescope_diameter_m"],
            central_obstruction=spec["central_obstruction_ratio"],
            pupil_reflectivity=spec["pupil_reflectivity"],
            revision=spec["aperture_revision"], T=Float32), Backends.HostComputeDevice())
end

function Instruments.binding_values(::Val{:pupil_support}, declaration, configured, binding)
    telescope = configured_telescope(declaration, configured, binding)
    return copy(AdaptiveOpticsSim.Optics.pupil_mask(telescope))
end

function Instruments.binding_values(::Val{:pupil_coordinates}, declaration, configured, binding)
    n = pupil_binding_resolution(declaration, configured, binding)
    basis = Array{Float32}(undef, n, n, 2)
    center, radius = Float32((n + 1) / 2), Float32(n / 2)
    for j in axes(basis, 2), i in axes(basis, 1)
        basis[i,j,1] = (i-center)/radius
        basis[i,j,2] = (j-center)/radius
    end
    return basis
end
