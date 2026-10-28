# Cold expansion of declared plant response models into native AOS graph nodes.
function validate_responses(document, inputs; label="production graph input")
    responses = get(document, "responses", Dict())
    _declaration_object(responses, "simulation responses")
    length(responses) <= 16 || throw(ArgumentError("simulation allows at most 16 responses"))
    for (name, response) in responses
        name in inputs || throw(ArgumentError("response must name a $label"))
        fields(response, ("kind", "natural_frequency_hz", "damping_ratio", "schema"),
            ("kind", "natural_frequency_hz", "damping_ratio", "schema"), "plant response")
        response["kind"] == "second_order" || throw(ArgumentError("unknown plant response kind"))
        all(isfinite_positive, (response["natural_frequency_hz"], response["damping_ratio"])) ||
            throw(ArgumentError("response frequency and damping must be finite and positive"))
        _declaration_text(response["schema"], "response schema")
    end
    return nothing
end

function apply_responses!(graph, declaration, configured)
    responses = get(declaration.document, "responses", Dict())
    isempty(responses) && return graph
    graph["nodes"] = Dict{String,Any}[node for node in graph["nodes"]]
    for (name, response) in responses
        input = only(entry for entry in graph["inputs"] if entry["name"] == name)
        values = binding_values(declaration, configured, declaration.document["bindings"][input["binding"]])
        ndims(values) == 1 && eltype(values) === Float32 ||
            throw(ArgumentError("second-order response requires a Float32 vector input"))
        node_name = name * "_response"
        any(node -> node["name"] == node_name, graph["nodes"]) &&
            throw(ArgumentError("response node name collides with a declared node"))
        destination = input["destination"]
        destination_node = first(split(destination, '.'))
        index = findfirst(node -> node["name"] == destination_node, graph["nodes"])
        index === nothing && throw(ArgumentError("response input destination must name a declared node"))
        input["destination"] = node_name * ".input"
        insert!(graph["nodes"], index, Dict("name"=>node_name, "type"=>"second_order_response_f32",
            "config"=>Dict("count"=>length(values), "schema"=>response["schema"],
                "natural_frequency_hz"=>response["natural_frequency_hz"],
                "damping_ratio"=>response["damping_ratio"],
                "sample_period_s"=>declaration.document["frame_period_s"])))
        push!(get!(graph, "links", []), Dict("source"=>node_name*".output", "destination"=>destination))
    end
    return graph
end
