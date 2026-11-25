"""A cold projection of one built regular graph, with its original provenance.

`graph` is prepared scientific storage owned by the caller until an initial
calibration endpoint accepts it. `document`, `bindings`, `parameters`,
`source_graph_sha256`, `parameter_sources` and `parameter_sha256` retain the
projection's configuration and exact FITS input provenance. Startup adds
`provenance` from the revalidated artifacts without changing the graph authority.
Copy construction replaces only explicit metadata fields; it never copies,
closes or transfers the scientific graph or its arrays.
"""
struct GraphProjection{G,D,B,P,S,H,V}
    graph::G
    document::D
    bindings::B
    parameters::P
    source_graph_sha256::String
    parameter_sources::S
    parameter_sha256::H
    provenance::V
end
function GraphProjection(
    graph;
    document,
    bindings,
    parameters,
    source_graph_sha256,
    parameter_sources,
    parameter_sha256,
    provenance = nothing,
)
    return GraphProjection(
        graph,
        document,
        bindings,
        parameters,
        source_graph_sha256,
        parameter_sources,
        parameter_sha256,
        provenance,
    )
end
function GraphProjection(
    projection::GraphProjection;
    graph = projection.graph,
    document = projection.document,
    bindings = projection.bindings,
    parameters = projection.parameters,
    source_graph_sha256 = projection.source_graph_sha256,
    parameter_sources = projection.parameter_sources,
    parameter_sha256 = projection.parameter_sha256,
    provenance = projection.provenance,
)
    return GraphProjection(
        graph;
        document,
        bindings,
        parameters,
        source_graph_sha256,
        parameter_sources,
        parameter_sha256,
        provenance,
    )
end

# An untransferred projection owns the prepared execution.
function Base.close(projection::GraphProjection)
    return FilterGraphPipeWire.close_execution(projection.graph)
end

"An ordered complete set of explicitly named command graph projections."
const NamedGraphProjections =
    NamedTuple{Names,T} where {Names,T<:Tuple{Vararg{GraphProjection}}}

# Generated initial-calibration graphs retain the built regular graph as their
# sole scientific authority. This walk is cold configuration work, not execution.
function calibration_output(value::AbstractString, name)
    return Dict{String,Any}("endpoint" => String(value), "name" => String(name))
end
function calibration_output(value, name)
    declaration = deepcopy(value)
    declaration["name"] = String(name)
    return declaration
end

function calibration_output_selection(outputs::Tuple)
    foreach(validate_projected_name, outputs)
    return outputs, outputs
end
function calibration_output_selection(outputs::NamedTuple)
    foreach(validate_projected_name, keys(outputs))
    foreach(validate_projected_source, values(outputs))
    return values(outputs), keys(outputs)
end

function calibration_selected_output(source::Symbol, external_outputs, nodes)
    haskey(external_outputs, source) || throw(ArgumentError("unknown projected output"))
    return calibration_port(external_outputs[source])
end
function calibration_selected_output(source::AbstractString, external_outputs, nodes)
    endpoint, node = calibration_endpoint(source)
    haskey(nodes, node) || throw(ArgumentError("unknown projected output Node $node"))
    return (; endpoint, node, name = Symbol(last(split(endpoint, ':'))))
end

validate_calibration_output_endpoints(::Tuple, endpoints) = nothing
function validate_calibration_output_endpoints(::NamedTuple, endpoints)
    length(unique(endpoints)) == length(endpoints) ||
        throw(ArgumentError("duplicate projected output endpoint"))
    return nothing
end

calibration_output(source::Symbol, alias, port, external_outputs) =
    calibration_output(external_outputs[source], alias)
calibration_output(source::AbstractString, alias, port, external_outputs) =
    calibration_output(port.endpoint, alias)
calibration_output_declarations(outputs::Tuple, external_outputs, selected) =
    [deepcopy(external_outputs[name]) for name in outputs]
calibration_output_declarations(outputs::NamedTuple, external_outputs, selected) = [
    calibration_output(source, alias, port, external_outputs) for
    (alias, source, port) in zip(keys(outputs), values(outputs), selected)
]

"""
    calibration_graph(application; inputs, outputs, parameter_sources=Dict())

Derive and prepare one initial-calibration graph from a built regular graph.
`inputs` maps new external Port names to exact `"NODE:PORT"` data endpoints;
each endpoint either cuts one existing Link or retains one existing external
data input. `outputs` selects existing external output names as a Tuple, or maps
new external names to distinct existing output names or exact internal
`"NODE:PORT"` output endpoints as a NamedTuple. These
aliases change only external Port names, never scientific endpoints. The cold backward
closure retains complete Node declarations, their Links and parameter bindings.
Every data boundary must be explicitly selected; every retained external
Parameter Port must have its existing FITS binding. Inputs that do not reach a
selected output, ambiguous cuts and unknown endpoints reject before preparation.

`parameter_sources` maps retained external Parameter Port Symbols to typed
`Artifacts.FITSArtifact` sources. It replaces only those FITS bindings; the full
original graph and its original sources are prepared as the structural authority.
Arrays, unknown ports and overrides outside the projection are rejected.

Returns a `GraphProjection` with fields `graph`, `document`, `bindings`,
`parameters`, `source_graph_sha256`, `parameter_sources` and `parameter_sha256`.
The caller
owns the prepared graph and closes it with `FilterGraphPipeWire.close_execution`.
`document` is generated configuration, `bindings` retains the resolved FITS
sources, and `parameters` contains owned logical arrays keyed by external Port.
`parameter_sources` is an owned override mapping; `parameter_sha256` records each
resolved source's original byte hash from the same snapshot that supplied values.
The application and its graph/FITS files are never modified. This does not
preserve or transfer the state of a running regular controller.
"""
function Calibration.calibration_graph(
    application;
    inputs::NamedTuple,
    outputs::Union{Tuple,NamedTuple},
    parameter_sources = Dict(),
)
    Calibration.require_prepared_application(application)
    isempty(inputs) &&
        throw(ArgumentError("calibration projection requires explicit data inputs"))
    isempty(outputs) &&
        throw(ArgumentError("calibration projection requires selected outputs"))
    output_sources, output_names = calibration_output_selection(outputs)
    length(unique(output_sources)) == length(output_sources) ||
        throw(ArgumentError("duplicate projected output source"))
    length(unique(output_names)) == length(output_names) ||
        throw(ArgumentError("duplicate projected output name"))
    source = joinpath(application, "rtc", "graph.conf")
    source_hash = Calibration.digest(source)
    document = PipeWireAORTC.DeploymentConfiguration.decode(
        source, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
    )
    specification = document["filter.graph"]
    nodes = Dict{String,Any}()
    for node in specification["nodes"]
        name = node["name"]
        haskey(nodes, name) && throw(ArgumentError("duplicate graph Node $name"))
        nodes[name] = node
    end
    links = Dict{String,Any}()
    for link in get(specification, "links", [])
        endpoint, _ = calibration_endpoint(link["input"])
        calibration_endpoint(link["output"])
        haskey(links, endpoint) &&
            throw(ArgumentError("graph input has multiple Link producers: $endpoint"))
        links[endpoint] = link
    end
    external_inputs = Dict{String,Any}()
    for port in specification["inputs"]
        endpoint = calibration_port(port).endpoint
        haskey(external_inputs, endpoint) &&
            throw(ArgumentError("duplicate external graph input $endpoint"))
        haskey(links, endpoint) && throw(
            ArgumentError("graph input has both external and Link producers: $endpoint")
        )
        external_inputs[endpoint] = port
    end
    external_outputs = Dict{Symbol,Any}()
    for port in specification["outputs"]
        name = calibration_port(port).name
        haskey(external_outputs, name) &&
            throw(ArgumentError("duplicate external graph output $name"))
        external_outputs[name] = port
    end
    selected_outputs = map(
        source -> calibration_selected_output(source, external_outputs, nodes),
        output_sources,
    )
    endpoints = map(port -> port.endpoint, selected_outputs)
    validate_calibration_output_endpoints(outputs, endpoints)
    entries = GraphOwner.bindings(joinpath(application, "rtc", "parameters.conf"))
    validate_parameter_sources(parameter_sources)
    source_overrides = Dict{Symbol,PipeWireAORTC.Artifacts.FITSArtifact}()
    bound_names = Set(entry.port for entry in entries)
    external_names = Set(calibration_port(port).name for port in values(external_inputs))
    for (name, artifact) in parameter_sources
        validate_parameter_override_name(name, bound_names, external_names)
        validate_parameter_override_artifact(artifact)
        source_overrides[name] = artifact
    end
    cuts = Dict{String,Symbol}()
    for (name, value) in pairs(inputs)
        endpoint, node = calibration_endpoint(value)
        haskey(nodes, node) || throw(ArgumentError("unknown cut Node $node"))
        haskey(cuts, endpoint) &&
            throw(ArgumentError("duplicate projected input endpoint $endpoint"))
        haskey(links, endpoint) ||
            haskey(external_inputs, endpoint) ||
            throw(ArgumentError("cut is not an existing graph input: $endpoint"))
        cuts[endpoint] = name
    end

    # Preparing the authority validates exact endpoint roles and scientific
    # declarations. No graph samples execute during preparation.
    authority = Calibration.controller_graph(application)
    projected = nothing
    try
        parameter_names = Set(keys(FilterGraphs.parameter_formats(authority)))
        issubset(Set(keys(source_overrides)), parameter_names) ||
            throw(ArgumentError("override is not an external Parameter Port"))
        parameter_endpoints = Dict(
            endpoint => calibration_port(port).name for
            (endpoint, port) in external_inputs if
            calibration_port(port).name in parameter_names
        )
        any(endpoint -> haskey(parameter_endpoints, endpoint), keys(cuts)) &&
            throw(ArgumentError("a Parameter Port cannot be a probe/data cut"))
        selected = Set{String}()
        visiting = Set{String}()
        used_cuts = Set{String}()
        function visit(name)
            haskey(nodes, name) || throw(ArgumentError("unknown dependency Node $name"))
            name in visiting && throw(ArgumentError("cycle in calibration graph closure"))
            name in selected && return nothing
            push!(visiting, name)
            for (endpoint, link) in links
                calibration_endpoint(endpoint)[2] == name || continue
                if haskey(cuts, endpoint)
                    push!(used_cuts, endpoint)
                else
                    visit(calibration_endpoint(link["output"])[2])
                end
            end
            for endpoint in keys(external_inputs)
                calibration_endpoint(endpoint)[2] == name || continue
                haskey(parameter_endpoints, endpoint) && continue
                haskey(cuts, endpoint) ||
                    throw(ArgumentError("undeclared projected data boundary: $endpoint"))
                push!(used_cuts, endpoint)
            end
            delete!(visiting, name)
            push!(selected, name)
        end
        foreach(port -> visit(port.node), selected_outputs)
        used_cuts == Set(keys(cuts)) ||
            throw(ArgumentError("projected input does not reach a selected output"))

        retained_parameters = [
            port for
            port in specification["inputs"] if calibration_port(port).node in selected &&
                haskey(parameter_endpoints, calibration_port(port).endpoint)
        ]
        retained_names = Set(calibration_port(port).name for port in retained_parameters)
        bindings = filter(entry -> entry.port in retained_names, entries)
        Set(entry.port for entry in bindings) == retained_names ||
            throw(ArgumentError("projected Parameter Port is missing its FITS binding"))
        issubset(Set(keys(source_overrides)), retained_names) ||
            throw(ArgumentError("Parameter Port override is outside the projection"))
        bindings = [
            GraphOwner.FITSBinding(
                entry.port, get(source_overrides, entry.port, entry.source)
            ) for entry in bindings
        ]
        projected_document = deepcopy(document)
        projection = projected_document["filter.graph"]
        projection["nodes"] = [
            deepcopy(node) for node in specification["nodes"] if node["name"] in selected
        ]
        projection["links"] = [
            deepcopy(link) for link in get(specification, "links", []) if
            calibration_endpoint(link["input"])[2] in selected &&
                !haskey(cuts, link["input"])
        ]
        projection["inputs"] = vcat(
            Any[
                Dict("name" => String(name), "endpoint" => String(endpoint)) for
                (name, endpoint) in pairs(inputs)
            ],
            deepcopy(retained_parameters),
        )
        projection["outputs"] = calibration_output_declarations(
            outputs, external_outputs, selected_outputs
        )
        parameters = Dict{Symbol,Array}()
        parameter_sha256 = Dict{Symbol,String}()
        projected = mktempdir() do directory
            path = joinpath(directory, "graph.conf")
            PipeWireAORTC.ScienceExport.write_spa_config(path, projected_document)
            FilterGraphPipeWire.prepare_service_graph(
                path;
                initial_parameters = formats -> begin
                    prepared = GraphOwner.prepare_artifacts(bindings, formats)
                    for (port, artifact) in prepared
                        parameters[port] = artifact.data
                        parameter_sha256[port] = artifact.provenance["original_sha256"]
                    end
                    [port => artifact.data for (port, artifact) in prepared]
                end,
            )
        end
        Calibration.digest(source) == source_hash ||
            throw(ArgumentError("source graph changed during projection"))
        return GraphProjection(
            projected;
            document = projected_document,
            bindings,
            parameters,
            source_graph_sha256 = source_hash,
            parameter_sources = source_overrides,
            parameter_sha256,
        )
    catch
        projected === nothing || FilterGraphPipeWire.close_execution(projected)
        rethrow()
    finally
        FilterGraphPipeWire.close_execution(authority)
    end
end

validate_projected_name(name::Symbol) =
    isempty(String(name)) ?
    throw(
        ArgumentError(
            "projected output names must be Symbols and sources must be output names or endpoints",
        ),
    ) : nothing
validate_projected_name(name) = throw(
    ArgumentError(
        "projected output names must be Symbols and sources must be output names or endpoints",
    ),
)
validate_projected_source(source::Union{Symbol,AbstractString}) = nothing
validate_projected_source(source) = throw(
    ArgumentError(
        "projected output names must be Symbols and sources must be output names or endpoints",
    ),
)

validate_parameter_sources(sources::AbstractDict) = nothing
validate_parameter_sources(sources) =
    throw(ArgumentError("parameter_sources must be a mapping"))

function validate_parameter_override_name(name::Symbol, bound_names, external_names)
    name in bound_names && name in external_names ||
        throw(ArgumentError("unknown external Parameter Port override: $name"))
    return nothing
end
validate_parameter_override_name(name, bound_names, external_names) =
    throw(ArgumentError("unknown external Parameter Port override: $name"))

validate_parameter_override_artifact(artifact::PipeWireAORTC.Artifacts.FITSArtifact) =
    nothing
validate_parameter_override_artifact(artifact) =
    throw(ArgumentError("Parameter Port override must be a FITSArtifact"))

function Calibration.prepare_bundle_graph(calibration::AbstractString)
    bundle = Calibration.read_bundle(calibration)
    return FilterGraphPipeWire.prepare_service_graph(
        bundle.graph;
        initial_parameters = formats -> begin
            Set(string.(keys(formats))) == Set(bundle.parameter_names) || throw(
                ArgumentError("calibration runtime parameter manifest differs from graph"),
            )
            entries = [
                GraphOwner.FITSBinding(
                    name,
                    PipeWireAORTC.Artifacts.FITSArtifact(
                        bundle.artifacts[bundle.parameter_files[string(name)]];
                        axes = length(format.shape) > 1 ?
                               collect(reverse(1:length(format.shape))) : nothing,
                    ),
                ) for (name, format) in pairs(formats)
            ]
            GraphOwner.prepare_bindings(entries, formats)
        end,
    )
end
