const Instruments = PipeWireAORTC.InstrumentConfiguration

function Instruments.prepare_optical_components!(graph::AbstractDict, declaration::NamedTuple,
        configured::AbstractDict)
    for node in graph["nodes"]
        haskey(node, "preparation") || continue
        preparation = node["preparation"]
        config = Instruments.prepared_component_config(node["config"])
        settings = Dict(key => config[key] for key in ("resolution", "pupil_resolution", "wavelength_um", "temperature_c"))
        prepared = AdaptiveOpticsSim.Optics.Zemax.prepare_component(declaration.instrument.directory,
            preparation["recipe"], preparation["branch"]; settings, diameter_m=config["diameter_m"])
        concrete = Instruments.json_value(prepared.config)
        for key in Instruments.OPTIONAL_OPTICAL_CONFIG
            haskey(config, key) && (concrete[key] = deepcopy(config[key]))
        end
        node["config"] = concrete
        delete!(node, "preparation")
    end
    return graph
end

function Instruments.optical_graph_document(declaration::NamedTuple, configured::AbstractDict,
        mode::AbstractString)
    graphs = AdaptiveOpticsSim.Optics.Zemax.execution_graphs(declaration.instrument.directory;
        settings=configured)
    haskey(graphs, mode) || throw(ArgumentError("unknown prepared optical path $mode"))
    # AOS freezes bounded generator documents. RTC's cold component/profile
    # expansion uses its ordinary mutable JSON document shape before sealing.
    document = Instruments.json_value(graphs[mode])
    observations = get(declaration.document, "observations", Dict())
    if haskey(observations, mode)
        selection = observations[mode]
        response = Instruments.graph_document(declaration, configured;
            simulation_graph=selection["graph"])
        detector = only(node for node in response["nodes"] if node["name"] == selection["detector"])
        sampling = get(detector["config"], "pixel_sampling_m", nothing)
        sampling isa AbstractVector && length(sampling) == 2 &&
            all(Instruments.isfinite_positive, sampling) ||
            throw(ArgumentError("optical detector requires positive row/column pixel_sampling_m"))
        isapprox(sampling[1], sampling[2]; rtol=8eps(Float32), atol=0) ||
            throw(ArgumentError("PROPER spectral output currently requires square detector pixels"))
        # The selected central wavelength changes the native diffraction grid;
        # the physical camera pitch remains fixed across cold replacements.
        only(document["nodes"])["config"]["output_sampling_m"] = sampling[1]
    end
    return document
end

function configuration_binding_names(document, factories)
    names = Symbol[]
    for entry in document["nodes"]
        factory = getproperty(factories, Symbol(entry["type"]))
        config = AlgorithmGraphs.graph_node_configuration(factory,
            Instruments._instrument_seal(entry["config"]),
            Instruments._instrument_seal(get(entry, "bindings", Dict())))
        append!(names, AlgorithmGraphs.graph_node_bindings(factory, config))
    end
    return unique!(names)
end

function prepare_bindings(declaration, configured, names;
        target=Backends.HostComputeDevice(), target_names=())
    specs = declaration.document["bindings"]
    all(name -> haskey(specs, string(name)), names) ||
        throw(ArgumentError("instrument graph names an undeclared array binding"))
    retained = Ref(0)
    arrays = Tuple(map(names) do name
        source = Instruments.binding_values(declaration, configured, specs[string(name)])
        bytes = Base.checked_mul(sizeof(eltype(source)), length(source))
        bytes <= Owner.MAX_RETAINED_BYTES - retained[] ||
            throw(ArgumentError("instrument bindings exceed 512 MiB"))
        retained[] += bytes
        name in target_names ? copy_to_target(target, source) : source
    end)
    return NamedTuple{Tuple(names)}(arrays)
end

function PipeWireAORTC.InstrumentExport.simulator_port_contracts(path::AbstractString;
        settings=Dict())
    declaration = Instruments.load_simulation(path)
    configured = Instruments.settings(declaration, settings)
    document = Instruments.graph_document(declaration, configured)
    # Only construction bindings are needed for cold typed declarations.
    # Frame inputs, parameters and unselected profiles remain unopened.
    factories = configured_graph_node_types()
    names = configuration_binding_names(document, factories)
    bindings = prepare_bindings(declaration, configured, names)
    nodes = Tuple(map(document["nodes"]) do entry
        factory = getproperty(factories, Symbol(entry["type"]))
        name = Symbol(entry["name"])
        config = AlgorithmGraphs.graph_node_configuration(factory,
            Instruments._instrument_seal(entry["config"]),
            Instruments._instrument_seal(get(entry, "bindings", Dict())))
        props = Instruments._instrument_seal(get(entry, "props", Dict()))
        keywords = haskey(entry, "detector") ? (; detector=Symbol(entry["detector"])) : (;)
        if !isempty(keywords)
            factory(name, config, props; keywords...)
        elseif applicable(factory, name, config, props, bindings)
            factory(name, config, props, bindings)
        else
            factory(name, config, props)
        end
    end)
    atmosphere = any(entry -> entry["name"] == "atmosphere_opd", get(document, "outputs", []))
    imaging = OpticalObservation.imaging_configuration(declaration)
    return OpticalObservation.port_contracts(nodes; atmosphere, imaging)
end

"""
    prepare_system(path; settings=NamedTuple(), calibration=false, simulation_graph=...,
        target=HostComputeDevice(), execution=StreamGraphExecution())

Prepare an ordinary typed AOS graph from an instrument declaration. The default
selects `production`; `calibration=true` selects its ideal diagnostic graph.
`simulation_graph="internal-source"` selects that explicitly declared optical
path; `"dark"` selects declared zero detector photon rate. Both use the same
typed preparation and execution interfaces.
Without an HIL declaration, an explicitly named graph uses that same compiler
and bindings, and returns `boundary=nothing` and `driver=nothing`. No RTC control
or lifecycle owner is created. The result retains `declaration` and `configured`.
"""
function Instruments.prepare_system(path::AbstractString;settings=NamedTuple(),calibration=false,
        simulation_graph=calibration ? "calibration" : "production",
        target=Backends.HostComputeDevice(),execution=StreamGraphExecution())
    declaration = Instruments.load_simulation(path)
    configured = Instruments.settings(declaration,settings)
    document = Instruments.graph_document(declaration,configured;calibration,simulation_graph)
    factories = configured_graph_node_types()
    runtime_names = Symbol[]
    for (section,field) in (("inputs","binding"),("parameters","binding"),("delayed_links","initial"))
        for entry in get(document,section,[])
            push!(runtime_names, Symbol(entry[field]))
        end
    end
    unique!(runtime_names)
    names = unique(vcat(runtime_names, configuration_binding_names(document, factories)))
    bindings = prepare_bindings(declaration, configured, names; target, target_names=runtime_names)
    definition = load_algorithm_graph(document;bindings,node_types=factories)
    for node in definition.nodes
        validate_sample_period(node.config, declaration.document["frame_period_s"])
    end
    graph = prepare_algorithm_graph(definition;target,execution)
    boundary = if haskey(declaration.document, "hil")
        hil = declaration.document["hil"]
        Instruments.fields(hil,("command_input","frame_output"),("command_input","frame_output"),"instrument HIL boundary")
        prepare_graph_hil_boundary(graph;
            command_input=configured_command_inputs(hil["command_input"]),frame_output=Symbol(hil["frame_output"]))
    else
        nothing
    end
    frame_period_s = Float32(declaration.document["frame_period_s"])
    isfinite(frame_period_s) && frame_period_s>0 || throw(ArgumentError("invalid instrument frame period"))
    period_ns = round(UInt64,Float64(frame_period_s)*1e9)
    driver = boundary === nothing ? nothing : FixedStepModelTimeDriver(PeriodicSchedule(;period_ns))
    mirror_names = Tuple(Symbol.(collect(keys(declaration.instrument.document["deformable_mirrors"]))))
    mirror_descriptions = NamedTuple{mirror_names}(Tuple(
        Instruments.mirror(declaration,configured,name).description
        for name in keys(declaration.instrument.document["deformable_mirrors"])))
    return (;definition,graph,boundary,target,frame_period_s,driver,mirror_descriptions,declaration,configured,
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

function Instruments.binding_values(::Val{:pupil_amplitude}, declaration, configured, binding)
    T = get(Dict("Float32" => Float32, "Float64" => Float64), binding["type"], nothing)
    T === nothing && throw(ArgumentError("pupil amplitude binding type must be Float32 or Float64"))
    support = Instruments.binding_values(Val(:pupil_support), declaration, configured, binding)
    return T.(support)
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

"""
    InstrumentConfiguration.prepare_external_pupil(path; settings=NamedTuple())

Prepare physical optical paths and their optional post-exposure AOS response
systems. The generated execution declaration names response graphs by graph key;
the authored source declaration names their instrument-relative YAML files.
AOS retains exposure accumulation, response execution, and reset ownership.
"""
function Instruments.prepare_external_pupil(path::AbstractString; settings=NamedTuple())
    declaration = Instruments.load_simulation(path)
    haskey(declaration.document, "hil") &&
        throw(ArgumentError("external-pupil preparation requires standalone optical graphs"))
    configured = Instruments.settings(declaration, settings)
    paths = get(declaration.instrument.document, "optical_paths", Dict())
    isempty(paths) && throw(ArgumentError("external-pupil preparation requires physical optical_paths"))
    observations = get(declaration.document, "observations", Dict())
    optical = Dict{Symbol,Any}()
    durations = Dict{Symbol,ModelDuration}()
    selections = Dict{Symbol,Any}()
    for (name, physical_path) in paths
        haskey(declaration.graphs, name) || throw(ArgumentError("physical optical path has no execution graph $name"))
        optical[Symbol(name)] = Instruments.prepare_system(path; settings,
            simulation_graph=name).graph
        sensor = declaration.instrument.document["wavefront_sensors"][physical_path["sensor"]]
        acquisition = get(sensor, "acquisition", Dict())
        seconds = get(acquisition, "exposure_duration_s", nothing)
        Instruments.isfinite_positive(seconds) || throw(ArgumentError("physical optical path requires a sensor exposure duration"))
        durations[Symbol(name)] = ModelDuration(round(UInt64, seconds * 1e9))
        observation = (; output=:intensity, sampling_node=:optics)
        if haskey(observations, name)
            entry = observations[name]
            key = entry["graph"]
            document = Instruments.graph_document(declaration, configured; simulation_graph=key)
            output = only(filter(output -> output["name"] == "frame", document["outputs"]))
            output["source"] == entry["detector"] * ".frame" ||
                throw(ArgumentError("resolved observation frame must come from its declared detector"))
            node = only(filter(node -> node["name"] == entry["detector"], document["nodes"]))
            node["type"] == "detector" && get(node, "detector", nothing) ==
                declaration.document["components"][entry["detector"]]["template"] ||
                throw(ArgumentError("resolved observation detector differs from its component"))
            config = node["config"]
            haskey(sensor, "expected_schema") && sensor["expected_schema"] != config["frame_schema"] &&
                throw(ArgumentError("observation detector frame_schema differs from its physical sensor expected_schema"))
            sampling = config["pixel_sampling_m"]
            sampling isa AbstractVector && length(sampling) == 2 && all(Instruments.isfinite_positive, sampling) ||
                throw(ArgumentError("observation detector requires metric row/column pixel_sampling_m"))
            exposure = config["exposure_duration_s"]
            Instruments.isfinite_positive(exposure) && isapprox(exposure, seconds; rtol=8eps(Float32), atol=0) ||
                throw(ArgumentError("observation detector exposure differs from its physical sensor acquisition"))
            shape = (config["rows"], config["columns"])
            haskey(sensor, "detector_shape") && Tuple(sensor["detector_shape"]) != shape &&
                throw(ArgumentError("observation detector shape differs from its physical sensor"))
            response = (;graph=Instruments.prepare_system(path; settings, simulation_graph=key).graph,
                input=:photon_rate, output=:frame,
                normalized_to_photon_rate=entry["normalized_to_photon_rate"],
                frame_schema=config["frame_schema"],
                pixel_sampling_m=(sampling[1], sampling[2]), exposure_duration_s=exposure)
            observation = (;observation..., response)
        end
        selections[Symbol(name)] = observation
    end
    names = Tuple(Symbol.(sort!(collect(keys(paths)))))
    named(values) = NamedTuple{names}(Tuple(values[name] for name in names))
    return AlgorithmGraphs.prepare_external_pupil(named(optical);
        exposure_durations=named(durations), observations=named(selections))
end
