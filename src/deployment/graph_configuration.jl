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
    if haskey(result, "filter.composition")
        haskey(result, "filter.graph") && throw(ArgumentError("a graph cannot also declare a composition"))
        # Component graphs are resolved individually. The shared graph loader
        # validates the composition descriptor and its typed component ports.
        return result
    end
    for node in result["filter.graph"]["nodes"]
        haskey(node, "config") || continue
        node["config"] = graph_configuration_value(node["config"], context)
    end
    return result
end

"Bind a calibrated CoG flat reference before comparing an authored branch graph."
function calibrated_centroid_references(graph::AbstractDict, calibration::AbstractDict)
    result = deepcopy(graph)
    body = result["filter.graph"]
    for (branch, context) in calibration
        calibrated_centroid_reference!(body,branch,context)
    end
    return result
end

"Admit only the branch graphs and shared output graph named by one composition."
function calibrated_composition_paths(application, prepared, selected)
    descriptors = filter(entry -> haskey(entry.graph,"filter.composition"), prepared)
    length(descriptors) == 1 || throw(ArgumentError("additional calibrated graphs require one composition"))
    descriptor = only(descriptors)
    body = descriptor.graph["filter.composition"]
    validate_calibrated_composition(body)
    branches = body["branches"]
    validate_calibrated_branches(branches)
    function component(path)
        validate_composition_component(path)
        return D.relative_asset(application,relpath(joinpath(dirname(descriptor.path),path),application))
    end
    branch_paths = Dict{String,String}()
    for branch in branches
        validate_calibrated_branch(branch)
        validate_composition_branch_name(branch["name"])
        path = component(branch["graph"])
        haskey(branch_paths,path) && throw(ArgumentError("composition branches require distinct graphs"))
        branch_paths[path] = branch["name"]
    end
    Set(keys(branch_paths)) == Set(keys(selected.graphs)) &&
        all(path -> selected.graphs[path].name == branch_paths[path],keys(branch_paths)) ||
        throw(ArgumentError("composition branches differ from selected calibrated branches"))
    shared = component(body["shared"])
    if shared in keys(branch_paths) || shared == descriptor.path
        throw(ArgumentError("composition shared graph must be distinct"))
    end
    return union(Set(keys(branch_paths)), Set([shared,descriptor.path]))
end

# Decoded dictionaries/arrays may have different container types; scientific
# scalar types must remain exact (in Julia, true == 1 == 1.0).
function exact_graph_value(left::AbstractDict, right::AbstractDict)
    Set(keys(left)) == Set(keys(right)) || return false
    return all(key -> exact_graph_field(key,left,right), keys(left))
end
exact_graph_value(left::AbstractVector, right::AbstractVector) =
    length(left) == length(right) && all(exact_graph_value(a,b) for (a,b) in zip(left,right))
exact_graph_value(left, right) = typeof(left) === typeof(right) && isequal(left,right)

"Validate an exact calibrated graph with only appended exports of existing outputs."
function calibrated_graph_exports(graph::AbstractDict, calibrated::AbstractDict)
    current, frozen = deepcopy(graph), deepcopy(calibrated)
    body, baseline = get(current,"filter.graph",nothing), get(frozen,"filter.graph",nothing)
    validate_calibrated_graph_bodies(body, baseline)
    haskey(body,"outputs") == haskey(baseline,"outputs") || throw(ArgumentError("calibrated output declaration must remain present or absent"))
    outputs, original = pop!(body,"outputs",Any[]), pop!(baseline,"outputs",Any[])
    validate_calibrated_graph_outputs(outputs, original)
    exact_graph_value(current,frozen) || throw(ArgumentError("executed graph changes calibrated fields outside output exports"))
    length(outputs) >= length(original) &&
        all(exact_graph_value(outputs[index],original[index]) for index in eachindex(original)) ||
        throw(ArgumentError("calibrated output exports must remain an exact prefix"))
    added = outputs[length(original)+1:end]
    isempty(added) && return added
    endpoints = String[graph_export_endpoint(row) for row in original]
    names = String[name for row in original for name in graph_export_names(row)]
    for row in added
        validate_added_graph_export(row)
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
    local_context = selected_graph_context(context,application,directory)
    selectionpath = joinpath(directory,"selection.yaml")
    !local_context && !isfile(selectionpath) && return nothing
    isfile(selectionpath) || throw(ArgumentError("selected optical calibration receipt is missing"))
    selection = Common.read_yaml(D.relative_asset(application,relpath(selectionpath,application)))
    !local_context && !haskey(selection,"graphs") && return nothing
    local_context || throw(ArgumentError("selected optical calibration must use its generated context"))
    get(selection,"version",nothing) === 1 || throw(ArgumentError("optical calibration selection requires version 1"))
    descriptor = get(selection,"rtc_configuration",nothing)
    validate_selected_graph_rtc(descriptor, rtcpath)
    identity = get(selection,"calibration_identity",nothing)
    identity == get(rtc,"calibration_identity",nothing) || throw(ArgumentError("selected RTC calibration identity differs"))
    validate_selected_graph_identity(identity)
    indexpath = D.relative_asset(application,relpath(joinpath(directory,"calibration.yaml"),application))
    Common.sha256_file(indexpath) == get(selection,"calibration_index_sha256",nothing) ||
        throw(ArgumentError("selected optical calibration index hash differs"))
    index = Common.read_yaml(indexpath)
    get(index,"version",nothing) === 1 && get(index,"kind",nothing) == "optical-calibration-index" &&
        get(index,"calibration_identity",nothing) == identity || throw(ArgumentError("invalid selected optical calibration index"))
    graphs, branches = get(selection,"graphs",nothing), get(index,"branches",nothing)
    validate_selected_graph_branches(graphs, branches)
    Calibration = getfield(parentmodule(@__MODULE__),:InstrumentCalibration)
    result = Dict{String,Any}()
    for (name,path) in graphs
        validate_selected_branch_graph(name, path)
        entry = branches[name]
        validate_selected_branch_path(entry, name)
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
        if selected !== nothing && haskey(selected.graphs,path)
            graph = calibrated_centroid_references(graph,context["calibration"])
        end
        sources = "$source, $instrumentpath and the instrument definition"
        header = "Generated by PipeWireAORTC from $sources; do not edit.\nEdit the instrument source and rebuild."
        return (; path, sourcepath, graph, header)
    end
    all(entry -> entry.sourcepath == entry.path || !(entry.sourcepath in paths), prepared) ||
        throw(ArgumentError("graph destination must not overwrite another graph's source"))
    exports = Dict{String,Any}()
    if selected !== nothing
        expected = Set(keys(selected.graphs))
        if Set(paths) != expected
            Set(paths) == calibrated_composition_paths(application,prepared,selected) ||
                throw(ArgumentError("declared graphs differ from calibrated composition components"))
        end
        for entry in prepared
            haskey(selected.graphs,entry.path) || continue
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

function calibrated_centroid_reference!(body,branch,context::AbstractDict)
    haskey(context,"reference_centroid") || return nothing
    reference = context["reference_centroid"]
    validate_centroid_coordinates(reference)
    coordinates = filter(input -> centroid_coordinates_port(input,branch),get(body,"inputs",[]))
    isempty(coordinates) && return nothing # A different branch's template.
    length(coordinates) == 1 || throw(ArgumentError("ambiguous calibrated centroid coordinates"))
    endpoint = split(only(coordinates)["endpoint"],':')
    length(endpoint) == 2 && endpoint[2] == "coordinates" ||
        throw(ArgumentError("calibrated centroid coordinate port differs"))
    nodes = filter(node -> node["name"] == endpoint[1],body["nodes"])
    length(nodes) == 1 && only(nodes)["label"] == "center-of-gravity-f32" ||
        throw(ArgumentError("calibrated centroid requires center-of-gravity-f32"))
    properties = get!(only(nodes),"props",Dict{String,Any}())
    for (key,value) in zip(("reference-centroid-x","reference-centroid-y"),reference)
        authored = get(properties,key,0.0)
        validate_authored_centroid(authored, value)
        properties[key] = value
    end
    return nothing
end
calibrated_centroid_reference!(body,branch,context) = nothing

function validate_centroid_coordinates(reference::AbstractVector)
    length(reference) == 2 || throw(ArgumentError("calibrated centroid reference requires finite X,Y coordinates"))
    foreach(validate_centroid_coordinate,reference)
    return nothing
end
validate_centroid_coordinates(reference) = throw(ArgumentError("calibrated centroid reference requires finite X,Y coordinates"))

function validate_centroid_coordinate(value::AbstractFloat)
    isfinite(value) || throw(ArgumentError("calibrated centroid reference requires finite X,Y coordinates"))
    return nothing
end
validate_centroid_coordinate(value) = throw(ArgumentError("calibrated centroid reference requires finite X,Y coordinates"))

centroid_coordinates_port(input::AbstractDict,branch) = get(input,"name",nothing) == branch*"-coordinates"
centroid_coordinates_port(input,branch) = false

function validate_authored_centroid(authored::Real, value)
    isfinite(authored) && (iszero(authored) || authored == value) || throw(ArgumentError("authored centroid reference conflicts with calibration"))
    return nothing
end
validate_authored_centroid(authored, value) = throw(ArgumentError("authored centroid reference conflicts with calibration"))

validate_authored_centroid(authored::Bool,value) = throw(ArgumentError("authored centroid reference conflicts with calibration"))

function validate_calibrated_composition(body::AbstractDict)
    Set(keys(body)) == Set(["branches","shared"]) || throw(ArgumentError("invalid calibrated composition descriptor"))
    return nothing
end
validate_calibrated_composition(body) = throw(ArgumentError("invalid calibrated composition descriptor"))

function validate_calibrated_branches(branches::AbstractVector)
    1 <= length(branches) <= 16 || throw(ArgumentError("calibrated composition requires bounded branches"))
    return nothing
end
validate_calibrated_branches(branches) = throw(ArgumentError("calibrated composition requires bounded branches"))

function validate_composition_component(path::String)
    !isempty(path) && !isabspath(path) || throw(ArgumentError("composition components require relative graph paths"))
    return nothing
end
validate_composition_component(path) = throw(ArgumentError("composition components require relative graph paths"))

function validate_calibrated_branch(branch::AbstractDict)
    haskey(branch,"name") && haskey(branch,"graph") || throw(ArgumentError("composition branch requires name and graph"))
    return nothing
end
validate_calibrated_branch(branch) = throw(ArgumentError("composition branch requires name and graph"))

validate_composition_branch_name(name::String) = nothing
validate_composition_branch_name(name) = throw(ArgumentError("composition branch name must be a string"))

validate_calibrated_graph_bodies(body::AbstractDict, baseline::AbstractDict) = nothing
validate_calibrated_graph_bodies(body, baseline) = throw(ArgumentError("calibrated graph requires filter.graph"))

validate_calibrated_graph_outputs(outputs::AbstractVector, original::AbstractVector) = nothing
validate_calibrated_graph_outputs(outputs, original) = throw(ArgumentError("graph outputs must be arrays"))

function validate_selected_graph_rtc(descriptor::AbstractDict, rtcpath)
    Set(keys(descriptor)) == Set(["path","sha256"]) && descriptor["path"] == basename(rtcpath) && descriptor["sha256"] == Common.sha256_file(rtcpath) || throw(ArgumentError("selected RTC configuration differs from calibration selection"))
    return nothing
end
validate_selected_graph_rtc(descriptor, rtcpath) = throw(ArgumentError("selected RTC configuration differs from calibration selection"))

validate_selected_graph_identity(identity::String) = nothing
validate_selected_graph_identity(identity) = throw(ArgumentError("selected RTC calibration identity differs"))

function validate_selected_graph_branches(graphs::AbstractDict, branches::AbstractDict)
    1 <= length(graphs) <= 16 && Set(keys(graphs)) == Set(keys(branches)) || throw(ArgumentError("selected graphs must name every calibrated branch"))
    return nothing
end
validate_selected_graph_branches(graphs, branches) = throw(ArgumentError("selected graphs must name every calibrated branch"))

function validate_selected_branch_graph(name::String, path::String)
    occursin(r"^[a-z][a-z0-9-]{0,31}$",name) || throw(ArgumentError("invalid calibrated branch graph"))
    return nothing
end
validate_selected_branch_graph(name, path) = throw(ArgumentError("invalid calibrated branch graph"))

function validate_selected_branch_path(entry::AbstractDict, name)
    get(entry,"path",nothing) == name || throw(ArgumentError("calibrated branch path differs"))
    return nothing
end
validate_selected_branch_path(entry, name) = throw(ArgumentError("calibrated branch path differs"))

exact_graph_field(key::String,left,right) = exact_graph_value(left[key],right[key])
exact_graph_field(key,left,right) = false

graph_export_endpoint(row::AbstractString) = row
graph_export_endpoint(row) = row["endpoint"]
graph_export_names(row::AbstractDict) = (row["name"],)
graph_export_names(row) = ()

function validate_added_graph_export(row::AbstractDict)
    Set(keys(row)) == Set(["name","endpoint"]) || throw(ArgumentError("added output exports require only a name and explicit endpoint"))
    foreach(key -> validate_added_graph_export_text(row[key]),("name","endpoint"))
    return nothing
end
validate_added_graph_export(row) = throw(ArgumentError("added output exports require only a name and explicit endpoint"))

function validate_added_graph_export_text(value::String)
    !isempty(strip(value)) || throw(ArgumentError("added output exports require only a name and explicit endpoint"))
    return nothing
end
validate_added_graph_export_text(value) = throw(ArgumentError("added output exports require only a name and explicit endpoint"))

selected_graph_context(context::String,application,directory) = normpath(joinpath(application,context)) == joinpath(directory,"context.yaml")
selected_graph_context(context,application,directory) = false
