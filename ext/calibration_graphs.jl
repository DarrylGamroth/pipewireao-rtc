# Generated initial-calibration graphs retain the built regular graph as their
# sole scientific authority. This walk is cold configuration work, not execution.
function calibration_endpoint(value)
    value isa AbstractString || throw(ArgumentError("graph endpoint must be a string"))
    parts = split(value, ':'; keepempty=true)
    length(parts) == 2 && all(!isempty, parts) ||
        throw(ArgumentError("graph endpoint must be NODE:PORT"))
    return String(value), String(first(parts))
end

function calibration_port(value)
    endpoint = value isa AbstractString ? value : value["endpoint"]
    endpoint, node = calibration_endpoint(endpoint)
    name = value isa AbstractString ? last(split(endpoint, ':')) : value["name"]
    return (; endpoint, node, name=Symbol(name))
end

"""
    calibration_graph(application; inputs, outputs)

Derive and prepare one initial-calibration graph from a built regular graph.
`inputs` maps new external Port names to exact `"NODE:PORT"` data endpoints;
each endpoint either cuts one existing Link or retains one existing external
data input. `outputs` selects existing external output names. The cold backward
closure retains complete Node declarations, their Links and parameter bindings.
Every data boundary must be explicitly selected; every retained external
Parameter Port must have its existing FITS binding. Inputs that do not reach a
selected output, ambiguous cuts and unknown endpoints reject before preparation.

Returns `(graph, document, bindings, parameters, source_graph_sha256)`. The caller
owns the prepared graph and closes it with `FilterGraphIsland.close_execution`.
`document` is generated configuration, `bindings` retains the original FITS
sources, and `parameters` contains owned logical arrays keyed by external Port.
The application and its graph/FITS files are never modified. This does not
preserve or transfer the state of a running regular controller.
"""
function Calibration.calibration_graph(application; inputs::NamedTuple, outputs::Tuple)
    Calibration.require_prepared_application(application)
    isempty(inputs) && throw(ArgumentError("calibration projection requires explicit data inputs"))
    isempty(outputs) && throw(ArgumentError("calibration projection requires selected outputs"))
    length(unique(outputs)) == length(outputs) || throw(ArgumentError("duplicate projected output"))
    source = joinpath(application, "rtc", "graph.conf")
    source_hash = Calibration.digest(source)
    document = PipeWireAORTC.DeploymentConfiguration.decode(source,
        get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao"))
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
        haskey(links, endpoint) && throw(ArgumentError("graph input has multiple Link producers: $endpoint"))
        links[endpoint] = link
    end
    external_inputs = Dict{String,Any}()
    for port in specification["inputs"]
        endpoint = calibration_port(port).endpoint
        haskey(external_inputs, endpoint) && throw(ArgumentError("duplicate external graph input $endpoint"))
        haskey(links, endpoint) && throw(ArgumentError("graph input has both external and Link producers: $endpoint"))
        external_inputs[endpoint] = port
    end
    external_outputs = Dict{Symbol,Any}()
    for port in specification["outputs"]
        name = calibration_port(port).name
        haskey(external_outputs, name) && throw(ArgumentError("duplicate external graph output $name"))
        external_outputs[name] = port
    end
    all(name -> haskey(external_outputs, name), outputs) || throw(ArgumentError("unknown projected output"))
    cuts = Dict{String,Symbol}()
    for (name, value) in pairs(inputs)
        endpoint, node = calibration_endpoint(value)
        haskey(nodes, node) || throw(ArgumentError("unknown cut Node $node"))
        haskey(cuts, endpoint) && throw(ArgumentError("duplicate projected input endpoint $endpoint"))
        haskey(links, endpoint) || haskey(external_inputs, endpoint) ||
            throw(ArgumentError("cut is not an existing graph input: $endpoint"))
        cuts[endpoint] = name
    end

    # Preparing the authority validates exact endpoint roles and scientific
    # declarations. No graph samples execute during preparation.
    authority = Calibration.controller_graph(application)
    projected = nothing
    try
        parameter_names = Set(keys(JuliaFilterGraph.parameter_formats(authority)))
        parameter_endpoints = Dict(endpoint => calibration_port(port).name
            for (endpoint, port) in external_inputs
            if calibration_port(port).name in parameter_names)
        any(endpoint -> haskey(parameter_endpoints, endpoint), keys(cuts)) &&
            throw(ArgumentError("a Parameter Port cannot be a probe/data cut"))
        selected = Set{String}()
        visiting = Set{String}()
        used_cuts = Set{String}()
        function visit(name)
            haskey(nodes, name) || throw(ArgumentError("unknown dependency Node $name"))
            name in visiting && throw(ArgumentError("cycle in calibration graph closure"))
            name in selected && return
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
                haskey(cuts, endpoint) || throw(ArgumentError("undeclared projected data boundary: $endpoint"))
                push!(used_cuts, endpoint)
            end
            delete!(visiting, name)
            push!(selected, name)
        end
        foreach(name -> visit(calibration_port(external_outputs[name]).node), outputs)
        used_cuts == Set(keys(cuts)) || throw(ArgumentError("projected input does not reach a selected output"))

        retained_parameters = [port for port in specification["inputs"]
            if calibration_port(port).node in selected &&
                haskey(parameter_endpoints, calibration_port(port).endpoint)]
        retained_names = Set(calibration_port(port).name for port in retained_parameters)
        entries = GraphOwner.bindings(joinpath(application, "rtc", "parameters.conf"))
        bindings = filter(entry -> entry.port in retained_names, entries)
        Set(entry.port for entry in bindings) == retained_names ||
            throw(ArgumentError("projected Parameter Port is missing its FITS binding"))
        projected_document = deepcopy(document)
        projection = projected_document["filter.graph"]
        projection["nodes"] = [deepcopy(node) for node in specification["nodes"] if node["name"] in selected]
        projection["links"] = [deepcopy(link) for link in get(specification, "links", [])
            if calibration_endpoint(link["input"])[2] in selected && !haskey(cuts, link["input"])]
        projection["inputs"] = vcat(Any[Dict("name"=>String(name), "endpoint"=>String(endpoint))
            for (name, endpoint) in pairs(inputs)], deepcopy(retained_parameters))
        projection["outputs"] = [deepcopy(external_outputs[name]) for name in outputs]
        parameters = Dict{Symbol,Array}()
        projected = mktempdir() do directory
            path = joinpath(directory, "graph.conf")
            PipeWireAORTC.ScienceExport.write_spa_config(path, projected_document)
            options = FilterGraphIsland.parse_arguments([
                "--graph", path, "--check", "--execution", "complete-frame"])
            FilterGraphIsland.prepare_service_graph(options; initial_parameters=formats -> begin
                updates = GraphOwner.prepare_bindings(bindings, formats)
                foreach(pair -> (parameters[first(pair)] = last(pair)), updates)
                updates
            end)
        end
        Calibration.digest(source) == source_hash || throw(ArgumentError("source graph changed during projection"))
        return (; graph=projected, document=projected_document, bindings, parameters,
            source_graph_sha256=source_hash)
    catch
        projected === nothing || FilterGraphIsland.close_execution(projected)
        rethrow()
    finally
        FilterGraphIsland.close_execution(authority)
    end
end
