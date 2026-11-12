function PipeWireAORTC.InstrumentExport.localize_optical_preparation!(
    source::AbstractString, destination::AbstractString
)
    AdaptiveOpticsSim.Optics.Zemax.validate_provenance(source)
    AdaptiveOpticsSim.Optics.Zemax.prepare(destination; yamlfmt = nothing)
    return nothing
end

const Instruments = PipeWireAORTC.InstrumentConfiguration

Instruments.graph_node_types() = configured_graph_node_types()

function Instruments.validate_prepared_optics(declaration::NamedTuple)
    AdaptiveOpticsSim.Optics.Zemax.validate_provenance(declaration.instrument.directory)
    return nothing
end

function Instruments.prepare_optical_components!(
    graph::AbstractDict, declaration::NamedTuple, configured::AbstractDict
)
    for node in graph["nodes"]
        haskey(node, "preparation") || continue
        preparation = node["preparation"]
        preparation["kind"] == "ideal_pupil_relay" && continue
        preparation["kind"] == "zemax" ||
            throw(ArgumentError("unsupported optical component preparation"))
        config = Instruments.prepared_component_config(node["config"])
        settings = Dict(
            key => config[key] for
            key in ("resolution", "pupil_resolution", "wavelength_um", "temperature_c")
        )
        prepared = AdaptiveOpticsSim.Optics.Zemax.prepare_component(
            declaration.instrument.directory,
            preparation["recipe"],
            preparation["branch"];
            settings,
            diameter_m = config["diameter_m"],
            frozen = haskey(declaration.document, "optical_model"),
            phase_screens = get(config, "phase_screens", ()),
            pupil_grid = get(config, "pupil_grid", nothing),
        )
        concrete = Instruments.json_value(prepared.config)
        for key in Instruments.OPTIONAL_OPTICAL_CONFIG
            key in ("phase_screens", "pupil_grid") && continue
            haskey(config, key) && (concrete[key] = deepcopy(config[key]))
        end
        node["config"] = concrete
        delete!(node, "preparation")
    end
    for node in graph["nodes"]
        haskey(node, "preparation") || continue
        prepare_ideal_pupil_relay!(node, graph)
    end
    return graph
end

# A relay's source and receiver declarations own their grids and wavelength.
# Resolve these once while cold rather than copying geometry into authoring files.
function prepare_ideal_pupil_relay!(node, graph)
    preparation = Instruments.fields(
        node["preparation"],
        ("kind", "source", "destination"),
        ("kind", "source", "destination"),
        "ideal pupil relay preparation",
    )
    preparation["kind"] == "ideal_pupil_relay" ||
        throw(ArgumentError("unsupported pupil relay preparation"))
    config = Instruments.fields(
        node["config"], ("axes",), ("axes",), "derived pupil relay config"
    )
    source = only(filter(n -> n["name"] == preparation["source"], graph["nodes"]))
    destination = only(filter(n -> n["name"] == preparation["destination"], graph["nodes"]))
    source["type"] in ("proper_optical_train_f32", "proper_optical_train_f64") ||
        throw(ArgumentError("ideal pupil relay source must declare a PROPER field"))
    expected_type =
        source["type"] == "proper_optical_train_f32" ? "ideal_pupil_relay_f32" :
        "ideal_pupil_relay_f64"
    node["type"] == expected_type &&
    destination["type"] == "pyramid_rate_f32" &&
    expected_type == "ideal_pupil_relay_f32" || throw(
        ArgumentError("derived pupil relay requires matching supported field precision")
    )
    sc, dc = source["config"], destination["config"]
    get(sc, "output_quantity", nothing) == "electric_field" &&
    get(dc, "input_quantity", nothing) == "electric_field" ||
        throw(ArgumentError("ideal pupil relay requires complex field source and receiver"))
    wavelength = sc["wavelength_um"] * 1e-6
    isapprox(wavelength, dc["source_wavelength_m"]; rtol = 8eps(Float32), atol = 0) ||
        throw(ArgumentError("ideal pupil relay source and PWFS wavelengths differ"))
    source_link = Dict(
        "source" => source["name"] * ".output", "destination" => node["name"] * ".input"
    )
    destination_link = Dict(
        "source" => node["name"] * ".output",
        "destination" => destination["name"] * ".electric_field",
    )
    source_link in graph["links"] && destination_link in graph["links"] ||
        throw(ArgumentError("ideal pupil relay preparation must match actual graph links"))
    AOSOwner.load_instrument(:Proper)
    factory = AlgorithmGraphs.proper_optical_train_node_factory(T = Float32)
    definition = Base.invokelatest(
        factory, Symbol(source["name"]), Instruments._instrument_seal(sc), (;), (;)
    )
    pitch = Base.invokelatest(AlgorithmGraphs.optical_sampling_m, definition.config)
    receiver_pitch = dc["telescope_diameter_m"] / dc["resolution"]
    node["config"] = Dict(
        "input_size" => [sc["resolution"], sc["resolution"]],
        "output_size" => [dc["resolution"], dc["resolution"]],
        "axes" => config["axes"],
        "input_sampling_m" => [pitch, pitch],
        "output_sampling_m" => [receiver_pitch, receiver_pitch],
        "wavelength_m" => wavelength,
        "input_schema" => definition.config.schemas[3],
        "output_schema" => dc["field_schema"],
    )
    delete!(node, "preparation")
    return node
end

function Instruments.optical_graph_document(
    declaration::NamedTuple, configured::AbstractDict, mode::AbstractString
)
    graphs = AdaptiveOpticsSim.Optics.Zemax.execution_graphs(
        declaration.instrument.directory; settings = configured
    )
    haskey(graphs, mode) || throw(ArgumentError("unknown prepared optical path $mode"))
    # AOS freezes bounded generator documents. RTC's cold component/profile
    # expansion uses its ordinary mutable JSON document shape before sealing.
    document = Instruments.json_value(graphs[mode])
    observations = get(declaration.document, "observations", Dict())
    variants = get(declaration.document["optical_model"], "variants", Dict())
    branch = haskey(variants, mode) ? variants[mode]["branch"] : mode
    if haskey(observations, branch)
        selection = observations[branch]
        response = Instruments.graph_document(
            declaration, configured; simulation_graph = selection["graph"]
        )
        detector = only(
            node for node in response["nodes"] if node["name"] == selection["detector"]
        )
        sampling = get(detector["config"], "pixel_sampling_m", nothing)
        validate_optical_sampling(sampling)
        isapprox(sampling[1], sampling[2]; rtol = 8eps(Float32), atol = 0) || throw(
            ArgumentError(
                "PROPER spectral output currently requires square detector pixels"
            ),
        )
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
        config = AlgorithmGraphs.graph_node_configuration(
            factory,
            Instruments._instrument_seal(entry["config"]),
            Instruments._instrument_seal(get(entry, "bindings", Dict())),
        )
        append!(names, AlgorithmGraphs.graph_node_bindings(factory, config))
    end
    return unique!(names)
end

function runtime_binding_names(document)
    names = Symbol[]
    for (section, field) in
        (("inputs", "binding"), ("parameters", "binding"), ("delayed_links", "initial"))
        append!(names, (Symbol(entry[field]) for entry in get(document, section, [])))
    end
    return unique!(names)
end

function prepare_bindings(
    declaration, configured, names; target = Backends.HostComputeDevice(), target_names = ()
)
    specs = declaration.document["bindings"]
    all(name -> haskey(specs, string(name)), names) ||
        throw(ArgumentError("instrument graph names an undeclared array binding"))
    retained = Ref(0)
    arrays = Tuple(
        map(names) do name
            source = Instruments.binding_values(
                declaration, configured, specs[string(name)]
            )
            bytes = Base.checked_mul(sizeof(eltype(source)), length(source))
            bytes <= AOSOwner.MAX_RETAINED_BYTES - retained[] ||
                throw(ArgumentError("instrument bindings exceed 512 MiB"))
            retained[] += bytes
            name in target_names ? copy_to_target(target, source) : source
        end,
    )
    return NamedTuple{Tuple(names)}(arrays)
end

function PipeWireAORTC.InstrumentExport.simulator_port_contracts(
    path::AbstractString; settings = Dict(), simulation_graph = "production"
)
    declaration = Instruments.load_simulation(path)
    configured = Instruments.settings(declaration, settings)
    if Instruments.graph_requires_proper(declaration, configured; simulation_graph)
        AOSOwner.load_instrument(:Proper)
    end
    # Loading Proper extends native node factories in a newer world.
    return Base.invokelatest(
        simulator_port_contracts, declaration, configured, simulation_graph
    )
end

function simulator_port_contracts(declaration, configured, simulation_graph)
    document = Instruments.graph_document(declaration, configured; simulation_graph)
    # Only construction bindings are needed for cold typed declarations.
    # Frame inputs, parameters and unselected profiles remain unopened.
    factories = configured_graph_node_types(declaration.directory)
    names = configuration_binding_names(document, factories)
    bindings = prepare_bindings(declaration, configured, names)
    nodes = Tuple(
        map(document["nodes"]) do entry
            factory = getproperty(factories, Symbol(entry["type"]))
            name = Symbol(entry["name"])
            config = AlgorithmGraphs.graph_node_configuration(
                factory,
                Instruments._instrument_seal(entry["config"]),
                Instruments._instrument_seal(get(entry, "bindings", Dict())),
            )
            props = Instruments._instrument_seal(get(entry, "props", Dict()))
            keywords =
                haskey(entry, "detector") ? (; detector = Symbol(entry["detector"])) : (;)
            if !isempty(keywords)
                factory(name, config, props; keywords...)
            elseif applicable(factory, name, config, props, bindings)
                factory(name, config, props, bindings)
            else
                factory(name, config, props)
            end
        end,
    )
    atmosphere = any(
        entry -> entry["name"] == "atmosphere_opd", get(document, "outputs", [])
    )
    imaging = OpticalObservation.imaging_configuration(declaration)
    return OpticalObservation.port_contracts(nodes; atmosphere, imaging)
end

# RTC GPU simulator paths require captured replay. AOS's lower-level reference
# execution policies remain available independently of this production boundary.
instrument_execution(::Backends.HostComputeDevice, execution) =
    execution === nothing ? StreamGraphExecution() : execution
function instrument_execution(::Backends.AcceleratorComputeDevice, execution)
    validate_accelerator_execution(execution)
    return CapturedGraphExecution()
end

"""
    prepare_system(path; settings=NamedTuple(), calibration=false, simulation_graph=...,
        target=HostComputeDevice(), execution=nothing)

Prepare an ordinary typed AOS graph from an instrument declaration. The default
selects `production`; `calibration=true` selects its ideal diagnostic graph.
`simulation_graph="internal-source"` selects that explicitly declared optical
path; `"dark"` selects declared zero detector photon rate. Both use the same
typed preparation and execution interfaces. CPU defaults to stream execution;
accelerators require captured execution, including explicit policy requests.
Without an HIL declaration, an explicitly named graph uses that same compiler
and bindings, and returns `boundary=nothing` and `driver=nothing`. No RTC control
or lifecycle owner is created. The result retains `declaration` and `configured`.
"""
function Instruments.prepare_system(
    path::AbstractString;
    settings = NamedTuple(),
    calibration = false,
    simulation_graph = calibration ? "calibration" : "production",
    target = Backends.HostComputeDevice(),
    execution = nothing,
)
    execution = instrument_execution(target, execution)
    declaration = Instruments.load_simulation(path)
    configured = Instruments.settings(declaration, settings)
    document = Instruments.graph_document(
        declaration, configured; calibration, simulation_graph
    )
    factories = configured_graph_node_types(declaration.directory)
    runtime_names = runtime_binding_names(document)
    names = unique(vcat(runtime_names, configuration_binding_names(document, factories)))
    bindings = prepare_bindings(
        declaration, configured, names; target, target_names = runtime_names
    )
    definition = load_algorithm_graph(document; bindings, node_types = factories)
    for node in definition.nodes
        validate_sample_period(node.config, declaration.document["frame_period_s"])
    end
    graph = prepare_algorithm_graph(definition; target, execution)
    boundary = if haskey(declaration.document, "hil")
        hil = declaration.document["hil"]
        Instruments.fields(
            hil,
            ("command_input", "frame_output"),
            ("command_input", "frame_output"),
            "instrument HIL boundary",
        )
        prepare_graph_hil_boundary(
            graph;
            command_input = configured_command_inputs(hil["command_input"]),
            frame_output = Symbol(hil["frame_output"]),
        )
    else
        nothing
    end
    frame_period_s = Float32(declaration.document["frame_period_s"])
    isfinite(frame_period_s) && frame_period_s > 0 ||
        throw(ArgumentError("invalid instrument frame period"))
    period_ns = round(UInt64, Float64(frame_period_s) * 1e9)
    driver =
        boundary === nothing ? nothing :
        FixedStepModelTimeDriver(PeriodicSchedule(; period_ns))
    mirror_names = Tuple(
        Symbol.(collect(keys(declaration.instrument.document["deformable_mirrors"])))
    )
    mirror_descriptions = NamedTuple{mirror_names}(
        Tuple(
            Instruments.mirror(declaration, configured, name).description for
            name in keys(declaration.instrument.document["deformable_mirrors"])
        ),
    )
    return (;
        definition,
        graph,
        boundary,
        target,
        frame_period_s,
        driver,
        mirror_descriptions,
        declaration,
        configured,
        settings = Instruments._instrument_seal(configured),
    )
end

configured_command_inputs(value::AbstractString) = Symbol(value)
configured_command_inputs(value::AbstractVector) = Tuple(Symbol.(value))

function configured_wire_contracts(declaration)
    return Tuple(
        (;
            frame_encoding = Symbol(entry["frame_encoding"]),
            frame_schema = entry["frame_schema"],
            command_schema = Instruments._instrument_seal(entry["command_schema"]),
            command_scale = configured_command_scales(
                Instruments._instrument_seal(entry["command_scale"])
            ),
        ) for entry in declaration.document["wire_contracts"]
    )
end

configured_command_scales(value::Real) = Float32(value)
configured_command_scales(values::NamedTuple) = map(Float32, values)

validate_sample_period(config, period) = nothing
if isdefined(AlgorithmGraphs, :SecondOrderResponseNodeConfig)
    function validate_sample_period(
        config::AlgorithmGraphs.SecondOrderResponseNodeConfig, period
    )
        config.sample_period_s == period || throw(
            ArgumentError(
                "response sample period differs from the simulation frame period"
            ),
        )
        return nothing
    end
end

# These cold bindings reuse AOS's telescope definition, including its aperture
# convention. The coefficients of the coordinate basis are metres of OPD;
# neither a physical stage angle nor a mirror reflection factor is inferred.
function pupil_binding_resolution(declaration, configured, binding)
    value = Instruments.Common.configuration_value(
        binding["resolution"], Instruments.configuration_context(declaration, configured)
    )
    resolution = Instruments.dimension(configured, value)
    Instruments.Artifacts.checked_shape((resolution, resolution, 2), sizeof(Float32))
    return Int(resolution)
end

function configured_telescope(declaration, configured, binding)
    resolution = pupil_binding_resolution(declaration, configured, binding)
    spec = declaration.instrument.document["telescope"]
    return AdaptiveOpticsSim.Optics.prepare_telescope(
        AdaptiveOpticsSim.Optics.TelescopeDefinition(;
            resolution,
            diameter = spec["telescope_diameter_m"],
            central_obstruction = spec["central_obstruction_ratio"],
            pupil_reflectivity = spec["pupil_reflectivity"],
            revision = spec["aperture_revision"],
            T = Float32,
        ),
        Backends.HostComputeDevice(),
    )
end

function Instruments.binding_values(::Val{:pupil_support}, declaration, configured, binding)
    telescope = configured_telescope(declaration, configured, binding)
    return copy(AdaptiveOpticsSim.Optics.pupil_mask(telescope))
end

function Instruments.binding_values(
    ::Val{:pupil_amplitude}, declaration, configured, binding
)
    T = get(Dict("Float32" => Float32, "Float64" => Float64), binding["type"], nothing)
    T === nothing &&
        throw(ArgumentError("pupil amplitude binding type must be Float32 or Float64"))
    support = Instruments.binding_values(
        Val(:pupil_support), declaration, configured, binding
    )
    return T.(support)
end

function Instruments.binding_values(
    ::Val{:pupil_coordinates}, declaration, configured, binding
)
    n = pupil_binding_resolution(declaration, configured, binding)
    basis = Array{Float32}(undef, n, n, 2)
    center, radius = Float32((n + 1) / 2), Float32(n / 2)
    for j in axes(basis, 2), i in axes(basis, 1)
        basis[i, j, 1] = (i - center) / radius
        basis[i, j, 2] = (j - center) / radius
    end
    return basis
end

"""
    InstrumentConfiguration.prepare_external_pupil(path; settings=NamedTuple(),
        target=HostComputeDevice(), execution=nothing)

Prepare physical optical paths and their optional post-exposure AOS response
systems. The generated execution declaration names response graphs by graph key;
the authored source declaration names their instrument-relative YAML files.
AOS retains exposure accumulation, response execution, and reset ownership.
The selected target and execution policy apply to every optical and response graph.
CPU defaults to stream execution; accelerators require captured execution. Explicit
non-captured accelerator policies are rejected, with no stream fallback.
"""
function Instruments.prepare_external_pupil(
    path::AbstractString;
    settings = NamedTuple(),
    target = Backends.HostComputeDevice(),
    execution = nothing,
    chopping = NamedTuple(),
)
    declaration = Instruments.load_simulation(path)
    execution = instrument_execution(target, execution)
    haskey(declaration.document, "hil") && throw(
        ArgumentError("external-pupil preparation requires standalone optical graphs")
    )
    configured = Instruments.settings(declaration, settings)
    paths = get(declaration.instrument.document, "optical_paths", Dict())
    isempty(paths) &&
        throw(ArgumentError("external-pupil preparation requires physical optical_paths"))
    observations = get(declaration.document, "observations", Dict())
    optical = Dict{Symbol,Any}()
    durations = Dict{Symbol,ModelDuration}()
    selections = Dict{Symbol,Any}()
    for (name, physical_path) in paths
        haskey(declaration.graphs, name) ||
            throw(ArgumentError("physical optical path has no execution graph $name"))
        optical[Symbol(name)] = Instruments.prepare_system(
            path; settings, simulation_graph = name, target, execution
        ).graph
        sensor = declaration.instrument.document["wavefront_sensors"][physical_path["sensor"]]
        acquisition = get(sensor, "acquisition", Dict())
        seconds = get(acquisition, "exposure_duration_s", nothing)
        Instruments.isfinite_positive(seconds) || throw(
            ArgumentError("physical optical path requires a sensor exposure duration")
        )
        durations[Symbol(name)] = ModelDuration(round(UInt64, seconds * 1e9))
        graph_document = Instruments.graph_document(
            declaration, configured; simulation_graph = name
        )
        intensity_outputs = filter(
            output -> output["name"] == "intensity", graph_document["outputs"]
        )
        length(intensity_outputs) == 1 ||
            throw(ArgumentError("optical branch requires one intensity output"))
        sampling_node = Symbol(first(split(only(intensity_outputs)["source"], '.')))
        observation = (; output = :intensity, sampling_node)
        if haskey(observations, name)
            entry = observations[name]
            key = entry["graph"]
            document = Instruments.graph_document(
                declaration, configured; simulation_graph = key
            )
            output = only(filter(output -> output["name"] == "frame", document["outputs"]))
            output["source"] == entry["detector"] * ".frame" || throw(
                ArgumentError(
                    "resolved observation frame must come from its declared detector"
                ),
            )
            node = only(
                filter(node -> node["name"] == entry["detector"], document["nodes"])
            )
            node["type"] == "detector" &&
            get(node, "detector", nothing) ==
            declaration.document["components"][entry["detector"]]["template"] || throw(
                ArgumentError("resolved observation detector differs from its component"),
            )
            config = node["config"]
            haskey(sensor, "expected_schema") &&
                sensor["expected_schema"] != config["frame_schema"] &&
                throw(
                    ArgumentError(
                        "observation detector frame_schema differs from its physical sensor expected_schema",
                    ),
                )
            sampling = config["pixel_sampling_m"]
            validate_observation_sampling(sampling)
            exposure = config["exposure_duration_s"]
            Instruments.isfinite_positive(exposure) &&
            isapprox(exposure, seconds; rtol = 8eps(Float32), atol = 0) || throw(
                ArgumentError(
                    "observation detector exposure differs from its physical sensor acquisition",
                ),
            )
            shape = (config["rows"], config["columns"])
            physical_detector = sensor["detector"]
            if haskey(physical_detector, "rows")
                physical_shape = (physical_detector["rows"], physical_detector["columns"])
                all(axis -> 0 < shape[axis] <= physical_shape[axis], 1:2) && all(
                    isapprox.(
                        sampling,
                        physical_detector["pixel_sampling_m"];
                        rtol = 8eps(Float32),
                        atol = 0,
                    ),
                ) || throw(
                    ArgumentError(
                        "observation ROI or pixel pitch differs from its physical camera",
                    ),
                )
                if haskey(acquisition, "roi_origin")
                    origin = acquisition["roi_origin"]
                    all(axis -> origin[axis] <= physical_shape[axis] - shape[axis], 1:2) ||
                        throw(
                            ArgumentError(
                                "observation ROI origin and shape exceed its physical camera",
                            ),
                        )
                end
            end
            haskey(sensor, "detector_shape") &&
                Tuple(sensor["detector_shape"]) != shape &&
                throw(
                    ArgumentError(
                        "observation detector shape differs from its physical sensor"
                    ),
                )
            response = (;
                graph = Instruments.prepare_system(
                    path; settings, simulation_graph = key, target, execution
                ).graph,
                input = :photon_rate,
                output = :frame,
                normalized_to_photon_rate = entry["normalized_to_photon_rate"],
                frame_schema = config["frame_schema"],
                pixel_sampling_m = (sampling[1], sampling[2]),
                exposure_duration_s = exposure,
            )
            observation = (; observation..., response)
        end
        if hasproperty(chopping, Symbol(name))
            selected = getproperty(chopping, Symbol(name))
            unfringed = Instruments.prepare_system(
                path;
                settings,
                simulation_graph = selected.unfringed_graph,
                target,
                execution,
            ).graph
            observation = (;
                observation...,
                chopping = (; unfringed, initial_phase = Symbol(selected.initial_phase)),
            )
        end
        selections[Symbol(name)] = observation
    end
    names = Tuple(Symbol.(sort!(collect(keys(paths)))))
    named(values) = NamedTuple{names}(Tuple(values[name] for name in names))
    return AlgorithmGraphs.prepare_external_pupil(
        named(optical);
        exposure_durations = named(durations),
        observations = named(selections),
    )
end

validate_accelerator_execution(::Union{Nothing,CapturedGraphExecution}) = nothing
validate_accelerator_execution(execution) =
    throw(ArgumentError("RTC accelerator preparation requires CapturedGraphExecution"))

function validate_optical_sampling(sampling::AbstractVector)
    length(sampling) == 2 && all(Instruments.isfinite_positive, sampling) || throw(
        ArgumentError("optical detector requires positive row/column pixel_sampling_m")
    )
    return nothing
end
validate_optical_sampling(sampling) =
    throw(ArgumentError("optical detector requires positive row/column pixel_sampling_m"))

function validate_observation_sampling(sampling::AbstractVector)
    length(sampling) == 2 && all(Instruments.isfinite_positive, sampling) || throw(
        ArgumentError("observation detector requires metric row/column pixel_sampling_m"),
    )
    return nothing
end
validate_observation_sampling(sampling) =
    throw(ArgumentError("observation detector requires metric row/column pixel_sampling_m"))

function Instruments.prepare_mirror_response(
    upstream,
    upstream_configuration,
    mirror;
    simulation_graph = "calibration",
    target = Backends.HostComputeDevice(),
)
    geometry = Instruments.mirror(upstream, upstream_configuration, mirror)
    document = Instruments.graph_document(upstream, upstream_configuration; simulation_graph)
    nodes = filter(node -> node["name"] == mirror, document["nodes"])
    length(nodes) == 1 || throw(
        ArgumentError("calibration must select one declared upstream mirror component")
    )
    node = only(nodes)
    # Select the existing typed node unchanged, including its construction and
    # parameter bindings. This preserves grid/coordinate/measured response and
    # physical command order instead of recreating an influence-function model.
    inputs = filter(
        entry -> entry["destination"] == mirror * ".pdm_command", document["inputs"]
    )
    length(inputs) == 1 ||
        throw(ArgumentError("mirror must have one complete physical command input"))
    selected_input = merge(only(inputs), Dict("name" => "command"))
    parameters = filter(
        entry -> startswith(entry["destination"], mirror * "."),
        get(document, "parameters", []),
    )
    response_document = Dict(
        "schema_version" => 1,
        "name" => "optical_calibration_mirror",
        "nodes" => [node],
        "inputs" => [selected_input],
        "parameters" => parameters,
        "outputs" => [Dict("name" => "opd", "source" => mirror * ".surface_opd")],
    )
    factories = configured_graph_node_types()
    names = unique(
        vcat(
            [Symbol(selected_input["binding"])],
            Symbol[Symbol(entry["binding"]) for entry in parameters],
            configuration_binding_names(response_document, factories),
        ),
    )
    bindings = prepare_bindings(
        upstream, upstream_configuration, names; target, target_names = names
    )
    definition = AlgorithmGraphs.load_algorithm_graph(
        response_document; bindings, node_types = factories
    )
    execution = instrument_execution(target, nothing)
    mirror_graph = AlgorithmGraphs.prepare_algorithm_graph(definition; target, execution)

    surface =
        command -> begin
            AlgorithmGraphs._with_prepared_device_execution_context(mirror_graph.context) do
                copyto!(AlgorithmGraphs.graph_input(mirror_graph, :command), command)
            end
            AlgorithmGraphs.step_graph!(mirror_graph)
            AlgorithmGraphs._with_prepared_device_execution_context(mirror_graph.context) do
                Array(AlgorithmGraphs.graph_output(mirror_graph, :opd))
            end
        end
    return (; geometry, node, mirror_graph, surface)
end
