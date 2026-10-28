# Post-exposure graphs are ordinary authored AOS graphs. This boundary owns
# references and detector identity; AOS owns their scientific execution.
observation_graph_name(path) = path * "_response"

function authored_observation_graph(directory, value)
    path = _declaration_text(value, "observation graph path")
    !isabspath(path) && normpath(path) == path && !occursin('\0', path) &&
        all(part -> !(part in (".", "..", "generated")), splitpath(path)) ||
        throw(ArgumentError("observation graph must be an instrument-relative authored asset outside generated"))
    isfile(joinpath(directory, path)) || throw(ArgumentError("observation graph must reference an existing authored file"))
    resolved = D.relative_asset(directory, path)
    "generated" in splitpath(relpath(resolved, realpath(directory))) &&
        throw(ArgumentError("observation graph must be authored outside generated"))
    return path
end

function observation_entries(document, instrument)
    observations = _declaration_object(get(document, "observations", Dict()), "simulation observations")
    length(observations) <= 16 || throw(ArgumentError("simulation observations exceed 16 entries"))
    paths = get(instrument, "optical_paths", Dict())
    components = get(document, "components", Dict())
    for (path, value) in observations
        haskey(paths, path) || throw(ArgumentError("observation names an unknown physical optical path $path"))
        entry = _declaration_fields(value, ("graph", "detector", "normalized_to_photon_rate"),
            ("graph", "detector", "normalized_to_photon_rate"), "observation $path")
        isfinite_positive(entry["normalized_to_photon_rate"]) ||
            throw(ArgumentError("observation normalized_to_photon_rate must be finite and positive"))
        detector = _declaration_identifier(entry["detector"], "observation detector")
        haskey(components, detector) || throw(ArgumentError("observation detector must name a declared component"))
        selection = components[detector]
        get(selection, "template", nothing) in ("ingaas", "hgcdte_linear_avalanche_array") ||
            throw(ArgumentError("observation detector requires an InGaAs or HgCdTe component"))
        get(selection, "sensor", nothing) == paths[path]["sensor"] ||
            throw(ArgumentError("observation detector sensor differs from the physical optical path"))
    end
    return observations
end

function observation_sources(document, instrument, directory)
    return Dict(observation_graph_name(path) => authored_observation_graph(directory, entry["graph"])
        for (path, entry) in observation_entries(document, instrument))
end

function validate_observations(document, instrument, directory, graphs; source=false)
    seen = Set{String}()
    for (path, entry) in observation_entries(document, instrument)
        key = source ? observation_graph_name(path) : _declaration_identifier(entry["graph"], "observation graph key")
        key in seen && throw(ArgumentError("observations must select distinct response graphs"))
        push!(seen, key)
        haskey(graphs, key) || throw(ArgumentError("observation names an absent response graph $key"))
        if !source
            haskey(get(instrument, "optical_paths", Dict()), key) &&
                throw(ArgumentError("observation response graph cannot replace a physical optical graph"))
            authored_observation_graph(directory, document["graphs"][key])
            haskey(graphs, path) || throw(ArgumentError("observation requires its physical optical graph $path"))
        end
        graph = graphs[key]
        inputs = filter(input -> input["name"] == "photon_rate", graph["inputs"])
        length(inputs) == 1 || throw(ArgumentError("observation graph requires one photon_rate input"))
        outputs = filter(output -> output["name"] == "frame", graph["outputs"])
        length(outputs) == 1 && only(outputs)["source"] == entry["detector"] * ".frame" ||
            throw(ArgumentError("observation frame output must come from its declared detector"))
        detectors = filter(node -> node["name"] == entry["detector"], graph["nodes"])
        length(detectors) == 1 && only(detectors)["type"] == "detector" &&
            get(only(detectors), "detector", nothing) == document["components"][entry["detector"]]["template"] ||
            throw(ArgumentError("observation graph must contain its declared detector component"))
    end
    return nothing
end

function optical_graph_names(document, instrument, names)
    # Only validated, explicitly selected graph keys may be removed here.
    observations = observation_entries(document, instrument)
    excluded = Set(entry["graph"] for entry in values(observations))
    all(key -> key in names, excluded) || throw(ArgumentError("observation names an absent response graph"))
    return filter(name -> !(name in excluded), collect(names))
end
