"Require the published CoG to subtract its calibrated reference before reconstruction."
function validate_optical_centroid_graph(graph, name, measurement)
    specification = graph["filter.graph"]
    parameter = Symbol(string(name)*"-coordinates")
    ports =
        filter(port -> calibration_port(port).name == parameter, specification["inputs"])
    length(ports) == 1 ||
        throw(ArgumentError("centroid graph requires its measured coordinates parameter"))
    endpoint = calibration_port(only(ports))
    nodes = filter(node -> node["name"] == endpoint.node, specification["nodes"])
    length(nodes) == 1 && endswith(endpoint.endpoint, ":coordinates") ||
        throw(ArgumentError("centroid coordinates must bind the measured CoG Node"))
    node = only(nodes)
    node["label"] == "center-of-gravity-f32" &&
    node["config"]["pixel_count"] == count(measurement.mask) || throw(
        ArgumentError("centroid graph differs from the calibrated selected pixel count"),
    )
    pixel_links = filter(
        link -> link["input"] == node["name"]*":pixels",
        get(specification, "links", []),
    )
    length(pixel_links) == 1 ||
        throw(ArgumentError("centroid graph requires one selected-pixel input"))
    source = only(pixel_links)["output"]
    selection = filter(
        candidate -> candidate["name"] == last(calibration_endpoint(source)),
        specification["nodes"],
    )
    length(selection) == 1 && endswith(source, ":selected-pixels") ||
        throw(ArgumentError("centroid graph must consume its calibrated pixel selection"))
    selected = only(selection)
    selected["label"] == "pixel-selection-f32" &&
    Tuple(selected["config"]["image_size"]) == size(measurement.mask) &&
    selected["config"]["mask"] == vec(permutedims(measurement.mask, (2, 1))) || throw(
        ArgumentError("centroid graph differs from the measured row-major pixel mask"),
    )
    any(
        port -> calibration_port(port).endpoint == selected["name"]*":image",
        get(specification, "inputs", []),
    ) &&
    !any(
        link -> link["input"] == selected["name"]*":image",
        get(specification, "links", []),
    ) || throw(
        ArgumentError(
            "centroid pixel selection must consume the calibrated detector image directly",
        ),
    )
    reconstruction_ports = filter(
        port -> calibration_port(port).name == Symbol(string(name)*"-reconstructor"),
        specification["inputs"],
    )
    length(reconstruction_ports) == 1 ||
        throw(ArgumentError("centroid graph requires its measured reconstructor parameter"))
    reconstruction_endpoint = calibration_port(only(reconstruction_ports))
    reconstruction = only(
        filter(
            candidate -> candidate["name"] == reconstruction_endpoint.node,
            specification["nodes"],
        ),
    )
    reconstruction["label"] == "dense-vector-reconstructor-f32" &&
    endswith(reconstruction_endpoint.endpoint, ":reconstructor") &&
    any(
        link ->
            link["output"] == node["name"]*":centroid-offset" &&
            link["input"] == reconstruction["name"]*":ordered-input",
        get(specification, "links", []),
    ) || throw(
        ArgumentError(
            "centroid reconstruction must consume the calibrated X,Y measurement directly",
        ),
    )
    reference_ports = filter(
        port -> calibration_port(port).name == Symbol(string(name)*"-modal-reference"),
        specification["inputs"],
    )
    length(reference_ports) == 1 || throw(
        ArgumentError("centroid graph requires its measured modal reference parameter"),
    )
    reference_endpoint = calibration_port(only(reference_ports))
    reference = only(
        filter(
            candidate -> candidate["name"] == reference_endpoint.node,
            specification["nodes"],
        ),
    )
    reference["label"] == "vector-offset-f32" &&
    endswith(reference_endpoint.endpoint, ":offset") &&
    any(
        link ->
            link["output"] == reconstruction["name"]*":output" &&
            link["input"] == reference["name"]*":requested",
        get(specification, "links", []),
    ) || throw(
        ArgumentError(
            "centroid graph must apply the calibrated measured-minus-reference sign",
        ),
    )
    properties = get(node, "props", Dict())
    get(properties, "reference-centroid-x", 0) == measurement.reference_centroid[1] &&
    get(properties, "reference-centroid-y", 0) == measurement.reference_centroid[2] &&
    get(properties, "flux-threshold", 0) == 0 &&
    get(properties, "pixel-threshold-enabled", false) === false || throw(
        ArgumentError(
            "centroid graph must subtract its calibrated reference and retain disabled thresholds",
        ),
    )
    return nothing
end

# Resolve retained optical controller templates only after acquiring real matrices.
validate_optical_graphs(graphs, contexts, names) = throw(
    ArgumentError("concrete graphs and contexts must name every recipe branch in order"),
)
function validate_optical_graphs(graphs::NamedTuple, contexts::NamedTuple, names)
    keys(graphs) == keys(contexts) == names || throw(
        ArgumentError(
            "concrete graphs and contexts must name every recipe branch in order",
        ),
    )
    foreach(validate_optical_context, contexts)
    for graph in graphs
        validate_optical_branch_graph(graph)
    end
    return nothing
end

function optical_publication_plan(application, selected; graphs, configuration, prefix)
    Export = PipeWireAORTC.InstrumentExport
    D = PipeWireAORTC.DeploymentConfiguration
    if graphs === nothing
        declaration =
            PipeWireAORTC.Common.read_yaml(D.relative_asset(application, configuration))
        IC.fields(
            declaration,
            (
                "graphs",
                "provenance",
                "destination",
                "rtc_configuration",
                "simulation_configuration",
                "recipe",
                "zero_command",
            ),
            ("graphs",),
            "optical publication configuration",
        )
        graphs = declaration["graphs"]
    end
    names = keys(selected.branches)
    validate_optical_authored_graphs(graphs, names)
    simulation = D.decode(D.relative_asset(application, "simulation.conf"), prefix)
    get(simulation, "version", nothing) in (4, 6) &&
    get(simulation, "mode", nothing) in ("external-pupil", "clocked-optical") || throw(
        ArgumentError("optical publication requires a built external-pupil application"),
    )
    rtc = IC.load_rtc(D.relative_asset(application, simulation["rtc_configuration"]))
    plant = simulation["plant"]
    options = PipeWireAORTC.AOSOwner.configuration(joinpath(application, "simulation.conf"))
    chopping = options.plant.chopping
    definition = D.relative_asset(application, plant["definition"])
    Calibration.digest(definition) == Calibration.digest(
        D.relative_asset(application, selected.document["optical_simulation"]),
    ) || throw(
        ArgumentError("optical recipe differs from the built external-pupil definition"),
    )
    declaration = IC.load_simulation(definition)
    IC.canonical(IC.settings(declaration, get(plant, "settings", Dict()))) ==
    IC.canonical(IC.settings(declaration, get(selected.document, "settings", Dict()))) ||
        throw(
            ArgumentError("optical recipe effective settings differ from built execution"),
        )
    contracts = Export.external_pupil_port_contracts(
        definition;
        settings = get(plant, "settings", Dict()),
        chopping,
    )
    frames = Dict(
        string(name)=>Dict(
            "frame_schema"=>contracts["sensors"][getproperty(selected.branches, name)]["schema"],
            "image_shape"=>contracts["sensors"][getproperty(selected.branches, name)]["shape"],
        ) for name in names
    )
    templates = NamedTuple{names}(
        Tuple(
            D.decode(D.relative_asset(application, graphs[string(name)]), prefix) for
            name in names
        ),
    )
    validate_optical_graphs(
        templates,
        NamedTuple{names}(Tuple(Dict() for _ in names)),
        names,
    )
    instrument =
        PipeWireAORTC.Common.read_json(D.relative_asset(application, "instrument.json"))
    return (; rtc, frames, templates, instrument, chopping)
end

function optical_publication_graphs(plan, calibration)
    names = keys(calibration.branches)
    keys(plan.templates) == names ||
        throw(ArgumentError("measured optical branches differ from authored templates"))
    dimensions = plan.rtc.document["dimensions"]
    command_count = optical_command_count(calibration.command_coordinates, dimensions)
    size(calibration.projection) ==
    (command_count, dimensions["controller_command_count"]) || throw(
        DimensionMismatch("measured physical projection differs from cold RTC dimensions"),
    )
    contexts = map(names) do name
        measured = getproperty(calibration.branches, name)
        shape = Tuple(
            get(
                plan.frames[string(name)],
                "image_shape",
                [dimensions["image_rows"], dimensions["image_columns"]],
            ),
        )
        size(measured.mask) == size(measured.reference) == shape || throw(
            DimensionMismatch("measured optical image differs from cold RTC dimensions"),
        )
        eltype(measured.mask) === Bool ||
            throw(ArgumentError("optical selection mask must contain Bool values"))
        measurement_count =
            optical_measurement_count(measured.measurement_kind, measured)
        size(measured.reconstructor) ==
        (dimensions["controller_command_count"], measurement_count) &&
        optical_selection_matches(
            measured.measurement_kind,
            measured,
            plan.frames[string(name)],
            dimensions,
        ) || throw(
            DimensionMismatch(
                "measured reconstructor differs from declared pixel selection",
            ),
        )
        context = Dict{String,Any}(deepcopy(plan.frames))
        for (branch_name, branch) in pairs(calibration.branches)
            entry =
                context[string(branch_name)] =
                    Dict{String,Any}(context[string(branch_name)])
            entry["pixel_selection_mask"] = vec(permutedims(branch.mask, (2, 1)))
            entry["selected_pixel_count"] = count(branch.mask)
            optical_measurement_context!(branch.measurement_kind, entry, branch)
        end
        # Match calibration_context's row-major FITS conversion exactly. The
        # bundle writer replaces this real measured mask with its typed FITS ref.
        context["pixel_selection_mask"] = vec(permutedims(measured.mask, (2, 1)))
        context
    end
    contexts = NamedTuple{names}(contexts)
    graphs = map(contexts, plan.templates) do calibration_context, template
        context = PipeWireAORTC.InstrumentExport.graph_context(
            plan.instrument;
            dimensions,
            mirror_controls = plan.rtc.controls["deformable_mirrors"],
            calibration = calibration_context,
        )
        graph = PipeWireAORTC.InstrumentExport.resolve_graph_configuration(
            template,
            context,
        )
        PipeWireAORTC.InstrumentExport.calibrated_centroid_references(
            graph,
            calibration_context,
        )
    end
    for (name, graph) in pairs(graphs)
        measured = getproperty(calibration.branches, name)
        validate_optical_measurement_graph(measured.measurement_kind, graph, name, measured)
        hasproperty(get(plan, :chopping, NamedTuple()), name) || continue
        actual = optical_frontend_identity(optical_chopped_document(graph, name))
        expected =
            calibration.report["provenance"]["measurement_frontend_identity"][string(name)]
        actual == expected || throw(
            ArgumentError(
                "published chopped measurement prefix differs from its calibrated execution",
            ),
        )
    end
    return (; graphs, contexts)
end

function publish_optical_bundles(result, destination, graphs, contexts)
    validate_optical_graphs(graphs, contexts, keys(result.calibration.branches))
    for (name, measurement) in pairs(result.calibration.branches)
        validate_optical_measurement_graph(
            measurement.measurement_kind,
            getproperty(graphs, name),
            name,
            measurement,
        )
    end
    for (name, identity) in get(
        result.calibration.report["provenance"],
        "measurement_frontend_identity",
        Dict(),
    )
        actual = optical_frontend_identity(
            optical_chopped_document(getproperty(graphs, Symbol(name)), Symbol(name)),
        )
        actual == identity || throw(
            ArgumentError(
                "published chopped graph differs from its calibrated measurement prefix",
            ),
        )
    end
    result.calibration.report["status"] == "accepted" ||
        throw(ArgumentError("cannot publish a rejected optical calibration"))
    mkpath(dirname(destination))
    temporary = mktempdir(dirname(destination); prefix = ".optical-calibration-")
    try
        reports = map(keys(graphs)) do name
            branch = joinpath(temporary, string(name))
            report = Calibration.calibrate_optical(
                result.calibration,
                branch;
                report = merge(result.report, Dict("branch"=>string(name))),
                context = getproperty(contexts, name),
                concrete_graph = getproperty(graphs, name),
                branch = name,
            )
            # Prepare the exact published graph with all real typed FITS inputs
            # before making the bundle index visible. This owns no live graph.
            mktempdir() do directory
                entries = [
                    Dict(
                        "port"=>parameter,
                        "path"=>joinpath(branch, "artifacts", filename),
                        "hdu"=>1,
                        "axes"=>any(
                            suffix -> endswith(parameter, suffix),
                            ("-modal-reference", "-reference-difference"),
                        ) ? [1] : [2, 1],
                    ) for (parameter, filename) in report["parameter_files"]
                ]
                bindings = joinpath(directory, "parameters.conf")
                PipeWireAORTC.Common.write_json(bindings, Dict("parameters"=>entries))
                GraphOwner.read_bindings(joinpath(branch, "graph.conf"), bindings)
            end
            report
        end
        reports = NamedTuple{keys(graphs)}(reports)
        first_branch = first(keys(reports))
        shared_names = (
            optical_projection_names(result.calibration.command_coordinates)...,
            optical_feedback_names(
                get(result.calibration, :physical_feedback_to_modes, nothing),
            )...,
        )
        hasproperty(result.calibration, :fast_reference) &&
            (shared_names = (shared_names..., "modes-to-reference"))
        shared = Dict(
            name=>Dict(
                "path"=>string(first_branch)*"/artifacts/"*name*".fits",
                "sha256"=>getproperty(reports, first_branch)["artifact_sha256"][name*".fits"],
            ) for name in shared_names
        )
        for report in reports, name in keys(shared)
            report["artifact_sha256"][name*".fits"] == shared[name]["sha256"] || throw(
                ArgumentError(
                    "branch bundles did not preserve identical physical projection artifacts",
                ),
            )
        end
        index = Dict(
            "version"=>1,
            "kind"=>"optical-calibration-index",
            "calibration_identity"=>result.report["calibration_identity"],
            "physical_projection"=>shared,
            "branches"=>Dict(
                string(name)=>Dict(
                    "path"=>string(name),
                    "result_sha256"=>Calibration.digest(
                        joinpath(temporary, string(name), "result.yaml"),
                    ),
                ) for name in keys(reports)
            ),
        )
        PipeWireAORTC.Common.write_yaml(
            joinpath(temporary, "calibration.yaml"),
            index;
            header = "Generated by PipeWireAORTC optical calibration; regenerate from built applications and the retained optical recipe.",
        )
        mv(temporary, destination; force = false)
        return merge(result, (; reports, index, directory = destination))
    finally
        isdir(temporary) && rm(temporary; recursive = true)
    end
end

function validate_optical_branch_graph(graph::AbstractDict)
    haskey(graph, "filter.graph") && !isempty(get(graph["filter.graph"], "nodes", [])) ||
        throw(
            ArgumentError(
                "publishing optical calibration requires concrete nonempty branch graphs",
            ),
        )
    return nothing
end
validate_optical_branch_graph(graph) = throw(
    ArgumentError(
        "publishing optical calibration requires concrete nonempty branch graphs",
    ),
)

validate_optical_context(context::AbstractDict) = nothing
validate_optical_context(context) =
    throw(ArgumentError("optical branch contexts must be mappings"))

function validate_optical_authored_graphs(graphs::AbstractDict, names)
    Set(keys(graphs)) == Set(string.(names)) || throw(
        ArgumentError("authored graphs must name every optical recipe branch exactly once"),
    )
    return nothing
end
validate_optical_authored_graphs(graphs, names) = throw(
    ArgumentError("authored graphs must name every optical recipe branch exactly once"),
)
