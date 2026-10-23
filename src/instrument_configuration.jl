"""Declarative instrument preparation shared by independent RTC applications.

SPA-JSON selects settings and artifacts for existing AOS YAML graphs. Only cold
preparation runs here; numerical execution remains in the prepared AOS graph.
"""
module InstrumentConfiguration

import JSON, SHA, FITSIO, Interpolations
import ..Common, ..DeploymentConfiguration, ..InstrumentDefinition, ..Artifacts
const D = DeploymentConfiguration

public load, settings, graph_document, scientific_definition, prepare_system,
    prepare_publication, prepare_simulation_configuration!, mirror, read_mirror_description, actuator_coordinates,
    actuator_grid_indices, actuator_index_map, source_grid_coordinates, configuration_context

function prepare_system end

include("instruments/settings.jl")
include("instruments/geometry.jl")
include("instruments/influence_functions.jl")
include("instruments/schema.jl")

function fields(value::AbstractDict, allowed, required, label)
    all(key -> key in allowed, keys(value)) && all(key -> haskey(value,key),required) ||
        throw(ArgumentError("invalid $label fields"))
    return value
end
fields(value, allowed, required, label) = throw(ArgumentError("$label must be an object"))

function bounded_document(path)
    isfile(path) && filesize(path) <= 1024 * 1024 ||
        throw(ArgumentError("instrument declaration must be a file of at most 1 MiB"))
    document = D.decode(path,get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    InstrumentDefinition.bounded(document,Ref(131072))
    return document
end

function graph_file(path)
    isfile(path) && filesize(path) <= 1024 * 1024 ||
        throw(ArgumentError("AOS graph must be a YAML file of at most 1 MiB"))
    document = Common.read_yaml(path)
    InstrumentDefinition.bounded(document, Ref(131072))
    return document
end

"Read one instrument declaration, retaining its application-relative asset boundary."
function load(path::AbstractString)
    document = bounded_document(path)
    declaration = (;path=abspath(path),directory=dirname(abspath(path)),document)
    validate_declaration(document,declaration.directory)
    return declaration
end

"Merge the declared defaults and validate the selected profile's startup settings."
function settings(declaration::NamedTuple, overrides::AbstractDict=Dict{String,Any}())
    document = declaration.document
    profile = get(overrides,"profile",get(document["defaults"],"profile",nothing))
    haskey(document["profiles"],profile) || throw(ArgumentError("unsupported instrument profile $profile"))
    schema = deepcopy(document["settings_schema"])
    merge!(schema["properties"],get(document["profiles"][profile],"settings_schema",Dict()))
    result = merge_settings(document["defaults"],overrides,schema)
    validate_settings(schema,result,result)
    return result
end
settings(declaration::NamedTuple, overrides::NamedTuple) = settings(declaration,json_value(overrides))

function settings_description(declaration, overrides)
    configured = settings(declaration,overrides)
    schema = deepcopy(declaration.document["settings_schema"])
    merge!(schema["properties"],get(declaration.document["profiles"][configured["profile"]],"settings_schema",Dict()))
    return Dict("package"=>declaration.document["id"],"settings"=>configured,"schema"=>schema)
end

function setting(value, path::AbstractString)
    for key in split(path,'.')
        value = value[key]
    end
    return value
end

function mirror(declaration, configured, name)
    spec = declaration.document["deformable_mirrors"][name]
    description = read_mirror_description(D.relative_asset(declaration.directory,spec["description"]))
    registration = _pupil_registration(_instrument_seal(setting(configured,spec["pupil_registration_setting"])))
    _require_pupil_geometry(description,registration)
    return (; description, registration)
end

"Build the cold reference context from selected settings and physical mirror descriptions."
function configuration_context(declaration, configured)
    instrument = deepcopy(declaration.document)
    for (name, spec) in instrument["deformable_mirrors"]
        geometry = mirror(declaration, configured, name)
        spec["actuator_count"] = command_count(geometry.description)
        spec["actuator_axis_count"] = _mirror_axis_count(geometry.description)
        spec["grid_shape"] = collect(geometry.description.layout.grid_shape)
        spec["description_json"] = read(D.relative_asset(declaration.directory, spec["description"]), String)
    end
    for sensor in values(instrument["wavefront_sensors"])
        rows, columns = sensor["detector_shape"]
        # SPA's packed-video construction property is width x height.
        sensor["video_frame_size"] = string(columns, 'x', rows)
        if haskey(sensor, "acquisition")
            acquisition = sensor["acquisition"]
            seconds = acquisition["exposure_duration_s"]
            acquisition["exposure_ns"] = round(UInt64, seconds * 1e9)
            acquisition["exposure_us"] = seconds * 1e6
        end
    end
    return Dict("instrument" => instrument, "settings" => deepcopy(configured))
end

transform(value, entry) = transform(Val(Symbol(get(entry,"transform","identity"))),value,entry)
transform(::Val{:identity}, value, entry) = deepcopy(value)
function transform(::Val{:gaussian_width}, value, entry)
    pitch = _influence_number(value,"Gaussian actuator pitch")
    coupling = _influence_number(entry["coupling"],"Gaussian mechanical coupling")
    pitch > 0 && 0 < coupling < 1 || throw(ArgumentError("invalid Gaussian pitch/coupling"))
    width = pitch / sqrt(-2 * log(coupling))
    isfinite(Float32(width)) && Float32(width) > 0 || throw(ArgumentError("invalid Float32 Gaussian width"))
    return width
end
transform(kind::Val, value, entry) = throw(ArgumentError("unknown instrument settings transform $kind"))

"Resolve profile and scalar settings into the existing AOS graph declaration schema."
function graph_document(declaration, configured; calibration=false)
    mode = calibration ? "calibration" : "production"
    graph = graph_file(D.relative_asset(declaration.directory,declaration.document["graphs"][mode]))
    profile_name = configured["profile"]
    profile = declaration.document["profiles"][profile_name]
    nodes = graph["nodes"]
    names = [node["name"] for node in nodes]
    length(unique(names)) == length(names) || throw(ArgumentError("duplicate instrument graph node"))
    replaced = Set{String}()
    for replacement in profile["nodes"]
        name = replacement["name"]
        index = findfirst(==(name),names)
        index === nothing && throw(ArgumentError("profile names absent node $name"))
        name in replaced && throw(ArgumentError("profile repeats node $name"))
        nodes[index] = deepcopy(replacement)
        push!(replaced,name)
    end
    parameters = filter(entry -> first(split(entry["destination"],'.')) ∉ replaced,
        get(graph,"parameters",[]))
    graph["parameters"] = vcat(parameters,deepcopy(profile["parameters"]))
    all_names = Set(names)
    # A binding may target a production-only node (e.g. atmosphere). Validate
    # against both declared modes so a misspelled target cannot disappear.
    for other in values(declaration.document["graphs"])
        root = graph_file(D.relative_asset(declaration.directory,other))
        union!(all_names,(node["name"] for node in root["nodes"]))
    end
    for entry in declaration.document["settings_bindings"]
        fields(entry,("setting","nodes","config","profiles","transform","coupling"),
            ("setting","nodes"),"settings binding")
        all(name -> name in all_names,entry["nodes"]) || throw(ArgumentError("settings binding names an absent graph node"))
        profile_name in get(entry,"profiles",[profile_name]) || continue
        value = transform(setting(configured,entry["setting"]),entry)
        for node in nodes
            node["name"] in entry["nodes"] || continue
            if haskey(entry,"config")
                node["config"][entry["config"]] = deepcopy(value)
            else
                InstrumentDefinition.object_value(value) || throw(ArgumentError("configuration merge requires an object"))
                merge!(node["config"],deepcopy(value))
            end
        end
    end
    graph["name"] = calibration ? graph["name"] : graph["name"] * "_" * profile_name
    return Common.configuration_value(graph, configuration_context(declaration, configured))
end

function binding_values(declaration, configured, binding::AbstractDict)
    kind = Val(Symbol(binding["kind"]))
    return binding_values(kind,declaration,configured,binding)
end
function binding_values(::Val{:zeros}, declaration, configured, binding)
    T = get(Dict(string(T)=>T for T in Artifacts.TARGET_TYPES),binding["type"],nothing)
    T === nothing && throw(ArgumentError("unsupported zero binding element type"))
    context = configuration_context(declaration, configured)
    shape = map(Common.configuration_value(binding["shape"], context)) do extent
        dimension(configured,extent)
    end
    dims = Artifacts.checked_shape(shape,sizeof(T))
    return zeros(T,dims)
end
dimension(configured, extent::AbstractString) = setting(configured,extent)
dimension(configured, extent::Integer) = extent
dimension(configured, extent) = throw(ArgumentError("invalid binding dimension"))
function binding_values(::Val{:mirror_coordinates}, declaration, configured, binding)
    values = mirror(declaration,configured,binding["mirror"])
    return actuator_coordinates(values.description; pupil_registration=values.registration)
end
function binding_values(::Val{:mirror_grid_indices}, declaration, configured, binding)
    values = mirror(declaration,configured,binding["mirror"])
    return actuator_grid_indices(values.description)
end
function measured_influences(declaration,configured,binding)
    values = mirror(declaration,configured,binding["mirror"])
    input = deepcopy(setting(configured,binding["setting"]))
    input["path"] = D.relative_asset(declaration.directory,input["path"])
    return _load_influence_functions(_instrument_seal(input),values.description,
        configured["pupil_resolution"],values.registration)
end
binding_values(::Val{:measured_influences},declaration,configured,binding) =
    measured_influences(declaration,configured,binding).modes
function binding_values(::Val{:fits},declaration,configured,binding)
    T = get(Dict(string(T)=>T for T in Artifacts.TARGET_TYPES),binding["type"],nothing)
    T === nothing && throw(ArgumentError("unsupported FITS binding element type"))
    source = Artifacts.FITSArtifact(D.relative_asset(declaration.directory,binding["path"]);
        hdu=binding["hdu"],axes=binding["axes"])
    return Artifacts.prepare(source,T,Tuple(binding["shape"])).data
end
binding_values(kind::Val,declaration,configured,binding) = throw(ArgumentError("unknown instrument binding kind $kind"))

include("instruments/metadata.jl")

end
