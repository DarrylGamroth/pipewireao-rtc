# Cold graph authoring references. Native consumers receive only concrete values.

"Build reference data from resolved geometry and declared instrument dimensions."
function graph_context(instrument::AbstractDict; dimensions::AbstractDict=Dict(), mirror_controls::AbstractDict=Dict(),
        calibration::AbstractDict=Dict())
    resolved = Dict{String,Any}(deepcopy(instrument))
    resolved["deformable_mirrors"] = Dict(name => merge(Dict{String,Any}(mirror),
        Dict("actuator_count" => length(mirror["layout"]["command_positions"])))
        for (name, mirror) in resolved["deformable_mirrors"])
    resolved["wavefront_sensors"] = Dict(name => merge(Dict{String,Any}(sensor),
        sensor_context(sensor["layout"]))
        for (name, sensor) in resolved["wavefront_sensors"])
    context = Dict{String,Any}("schemas" => Schemas.CATALOG, "instrument" => resolved, "rtc" => Dict{String,Any}("dimensions" => deepcopy(dimensions),
        "deformable_mirrors" => deepcopy(mirror_controls)))
    if haskey(dimensions,"selected_pixel_count")
        count = dimensions["selected_pixel_count"]
        InstrumentConfiguration.ispositive_integer(count) || throw(ArgumentError("selected pixel count must be positive"))
        context["rtc"]["selected_pixel_mask"] = trues(count)
    end
    context["calibration"] = graph_configuration_value(calibration, context)
    return context
end

function sensor_context(layout)
    haskey(layout,"detector_shape") || return Dict{String,Any}()
    fields = Dict{String,Any}("pixel_to_image" => pixel_to_image(layout["detector_shape"]))
    if get(layout, "kind", "shack_hartmann") == "shack_hartmann"
        fields["subaperture_count"] = length(layout["subaperture_origins"])
    end
    return fields
end

# Native image axes are [row,column]; display displacements are [x,y].
function pixel_to_image(shape)
    length(shape) == 2 && all(InstrumentConfiguration.ispositive_integer, shape) ||
        throw(ArgumentError("pixel normalization requires a positive detector shape"))
    rows, columns = shape
    return [1 / columns, 1 / rows]
end

import ..Common: configuration_value as graph_configuration_value,
    configuration_pointer as graph_pointer,
    configuration_reference_pointer as graph_reference_pointer,
    configuration_reference as graph_reference

"Resolve explicit references in node configuration, preserving topology and other fields."
function resolve_graph_configuration(graph::AbstractDict, context::AbstractDict)
    result = deepcopy(graph)
    for node in result["filter.graph"]["nodes"]
        haskey(node, "config") || continue
        node["config"] = graph_configuration_value(node["config"], context)
    end
    return result
end

# Decoded dictionaries/arrays may have different container types; scientific
# scalar types must remain exact (in Julia, true == 1 == 1.0).
function exact_graph_value(left::AbstractDict, right::AbstractDict)
    Set(keys(left)) == Set(keys(right)) || return false
    return all(key -> key isa String && exact_graph_value(left[key], right[key]), keys(left))
end
exact_graph_value(left::AbstractVector, right::AbstractVector) =
    length(left) == length(right) && all(exact_graph_value(a,b) for (a,b) in zip(left,right))
exact_graph_value(left, right) = typeof(left) === typeof(right) && isequal(left,right)

"Validate an exact calibrated graph with only appended exports of existing outputs."
function calibrated_graph_exports(graph::AbstractDict, calibrated::AbstractDict)
    current, frozen = deepcopy(graph), deepcopy(calibrated)
    body, baseline = get(current,"filter.graph",nothing), get(frozen,"filter.graph",nothing)
    body isa AbstractDict && baseline isa AbstractDict || throw(ArgumentError("calibrated graph requires filter.graph"))
    haskey(body,"outputs") == haskey(baseline,"outputs") || throw(ArgumentError("calibrated output declaration must remain present or absent"))
    outputs, original = pop!(body,"outputs",Any[]), pop!(baseline,"outputs",Any[])
    outputs isa AbstractVector && original isa AbstractVector || throw(ArgumentError("graph outputs must be arrays"))
    exact_graph_value(current,frozen) || throw(ArgumentError("executed graph changes calibrated fields outside output exports"))
    length(outputs) >= length(original) &&
        all(exact_graph_value(outputs[index],original[index]) for index in eachindex(original)) ||
        throw(ArgumentError("calibrated output exports must remain an exact prefix"))
    added = outputs[length(original)+1:end]
    isempty(added) && return added
    endpoint(row) = row isa AbstractString ? row : row["endpoint"]
    endpoints = String[endpoint(row) for row in original]
    names = String[row["name"] for row in original if row isa AbstractDict]
    for row in added
        row isa AbstractDict && Set(keys(row)) == Set(["name","endpoint"]) &&
            all(key -> row[key] isa String && !isempty(strip(row[key])), ("name","endpoint")) ||
            throw(ArgumentError("added output exports require only a name and explicit endpoint"))
        parts = split(row["endpoint"],':';limit=2)
        length(parts) == 2 && all(!isempty,parts) || throw(ArgumentError("added output endpoint must name node:port"))
        row["name"] in names && throw(ArgumentError("duplicate output export name"))
        # A bare existing endpoint already exports its node's sole output.
        any(value -> value == row["endpoint"] || (!occursin(':',value) && value == first(parts)),endpoints) &&
            throw(ArgumentError("duplicate output export endpoint"))
        push!(names,row["name"]); push!(endpoints,row["endpoint"])
    end
    # Reuse the owner compiler: it rejects unknown nodes/ports and duplicate
    # effective names, and supplies each existing output's actual typed format.
    Base.require(Main,:FilterGraphIsland)
    mktempdir() do directory
        path = joinpath(directory,"graph.conf")
        ScienceExport.write_spa_config(path,graph)
        Base.invokelatest(graph_port_contracts,path)
    end
    return added
end

"Read the existing generated optical selection; it is not a new adoption path."
function selected_calibration_graphs(application, configuration)
    configuration === nothing && return nothing
    rtcpath = D.relative_asset(application,configuration)
    rtc = Common.read_yaml(rtcpath)
    directory = dirname(rtcpath)
    context = get(rtc,"calibration",nothing)
    # Ordinary authored RTC contexts and composed physical-offset selections do
    # not point at a sibling context.yaml and retain their existing admission.
    local_context = context isa String && normpath(joinpath(application,context)) == joinpath(directory,"context.yaml")
    selectionpath = joinpath(directory,"selection.yaml")
    !local_context && !isfile(selectionpath) && return nothing
    isfile(selectionpath) || throw(ArgumentError("selected optical calibration receipt is missing"))
    selection = Common.read_yaml(D.relative_asset(application,relpath(selectionpath,application)))
    !local_context && !haskey(selection,"graphs") && return nothing
    local_context || throw(ArgumentError("selected optical calibration must use its generated context"))
    get(selection,"version",nothing) === 1 || throw(ArgumentError("optical calibration selection requires version 1"))
    descriptor = get(selection,"rtc_configuration",nothing)
    descriptor isa AbstractDict && Set(keys(descriptor)) == Set(["path","sha256"]) &&
        descriptor["path"] == basename(rtcpath) && descriptor["sha256"] == Common.sha256_file(rtcpath) ||
        throw(ArgumentError("selected RTC configuration differs from calibration selection"))
    identity = get(selection,"calibration_identity",nothing)
    identity == get(rtc,"calibration_identity",nothing) && identity isa String ||
        throw(ArgumentError("selected RTC calibration identity differs"))
    indexpath = D.relative_asset(application,relpath(joinpath(directory,"calibration.yaml"),application))
    Common.sha256_file(indexpath) == get(selection,"calibration_index_sha256",nothing) ||
        throw(ArgumentError("selected optical calibration index hash differs"))
    index = Common.read_yaml(indexpath)
    get(index,"version",nothing) === 1 && get(index,"kind",nothing) == "optical-calibration-index" &&
        get(index,"calibration_identity",nothing) == identity || throw(ArgumentError("invalid selected optical calibration index"))
    graphs, branches = get(selection,"graphs",nothing), get(index,"branches",nothing)
    graphs isa AbstractDict && branches isa AbstractDict && 1 <= length(graphs) <= 16 &&
        Set(keys(graphs)) == Set(keys(branches)) || throw(ArgumentError("selected graphs must name every calibrated branch"))
    Calibration = getfield(parentmodule(@__MODULE__),:InstrumentCalibration)
    result = Dict{String,Any}()
    for (name,path) in graphs
        name isa String && occursin(r"^[a-z][a-z0-9-]{0,31}$",name) && path isa String ||
            throw(ArgumentError("invalid calibrated branch graph"))
        entry = branches[name]
        entry isa AbstractDict && get(entry,"path",nothing) == name || throw(ArgumentError("calibrated branch path differs"))
        branch = D.relative_asset(application,relpath(joinpath(directory,name,"result.yaml"),application))
        Common.sha256_file(branch) == get(entry,"result_sha256",nothing) || throw(ArgumentError("calibrated branch result hash differs"))
        bundle = Calibration.read_bundle(dirname(branch))
        report = bundle.report
        get(report,"status",nothing) == "accepted" && get(report,"built_application_calibration",false) === true &&
            get(report,"deployable",false) === true && get(report,"diagnostic",true) === false &&
            get(get(report,"held_out",Dict()),"accepted",false) === true &&
            get(report,"calibration_identity",nothing) == identity && get(report,"branch",nothing) == name ||
            throw(ArgumentError("selected graph requires an accepted matched branch calibration"))
        graphpath = D.relative_asset(application,path)
        outside(relpath(graphpath,directory)) || throw(ArgumentError("executed graph must not overwrite selected calibration files"))
        haskey(result,graphpath) && throw(ArgumentError("calibrated branches require distinct graph paths"))
        result[graphpath] = (;name,graph=bundle.graph)
    end
    return (;directory,identity,graphs=result)
end

"Materialize declared source graphs before sealing; never read or modify a live session."
function prepare_graph_configurations!(application, declarations, instrumentpath, prefix;
        dimensions::AbstractDict=Dict(), mirror_controls::AbstractDict=Dict(),
        calibration::AbstractDict=Dict(), configuration=nothing)
    InstrumentDefinition.array_value(declarations) ||
        throw(ArgumentError("graph-configurations must be an array"))
    selected = selected_calibration_graphs(application,configuration)
    isempty(declarations) && selected === nothing && return nothing
    instrument = Common.read_json(D.relative_asset(application, instrumentpath))
    paths = Set{String}()
    prepared = map(declarations) do entry
        InstrumentDefinition.object_value(entry) && Set(keys(entry)) ⊆ Set(["path", "source"]) &&
            haskey(entry, "path") || throw(ArgumentError("invalid graph-configurations entry"))
        path = D.relative_asset(application, entry["path"])
        path in paths && throw(ArgumentError("duplicate graph configuration path"))
        push!(paths, path)
        context = graph_context(instrument; dimensions, mirror_controls, calibration)
        source = get(entry, "source", entry["path"])
        sourcepath = D.relative_asset(application, source)
        graph = resolve_graph_configuration(D.decode(sourcepath, prefix), context)
        sources = "$source, $instrumentpath and the instrument definition"
        header = "Generated by PipeWireAORTC from $sources; do not edit.\nEdit the instrument source and rebuild."
        return (; path, sourcepath, graph, header)
    end
    all(entry -> entry.sourcepath == entry.path || !(entry.sourcepath in paths), prepared) ||
        throw(ArgumentError("graph destination must not overwrite another graph's source"))
    exports = Dict{String,Any}()
    if selected !== nothing
        Set(paths) == Set(keys(selected.graphs)) || throw(ArgumentError("declared graphs differ from selected calibrated branches"))
        for entry in prepared
            frozen = selected.graphs[entry.path]
            added = calibrated_graph_exports(entry.graph,D.decode(frozen.graph,prefix))
            exports[frozen.name] = Dict("path"=>relpath(entry.path,application),
                "calibrated_graph_sha256"=>Common.sha256_file(frozen.graph),"added_outputs"=>added)
        end
    end
    for entry in prepared
        ScienceExport.write_spa_config(entry.path, entry.graph; header=entry.header)
    end
    if selected !== nothing
        for entry in values(exports)
            entry["executed_graph_sha256"] = Common.sha256_file(D.relative_asset(application,entry["path"]))
        end
        Common.write_yaml(joinpath(selected.directory,"graph-exports.yaml"),Dict("version"=>1,
            "calibration_identity"=>selected.identity,"graphs"=>exports,"application_accepted"=>false);
            header="Generated by InstrumentExport.prepare from selected frozen calibration graphs and executed graph exports; do not edit.")
    end
    return nothing
end
