"""Declarative instrument preparation shared by independent RTC applications.

YAML selects settings and artifacts for existing AOS YAML graphs. Only cold
preparation runs here; numerical execution remains in the prepared AOS graph.
"""
module InstrumentConfiguration

import JSON, SHA, FITSIO, Interpolations
import ..Schemas
import ..Common, ..DeploymentConfiguration, ..InstrumentDefinition, ..Artifacts
const D = DeploymentConfiguration

public load, load_simulation, load_simulation_source, load_rtc, settings, graph_document, scientific_definition, prepare_system, prepare_external_pupil,
    prepare_publication, prepare_simulation_configuration!, mirror, read_mirror_description, actuator_coordinates,
    actuator_grid_indices, actuator_index_map, source_grid_coordinates, configuration_context, calibration_context

function prepare_system end
function prepare_external_pupil end
function optical_graph_document(declaration, configured, mode)
    throw(ArgumentError("Zemax graph replanning requires AdaptiveOpticsSim, Proper and YAML"))
end
function prepare_optical_components!(graph, declaration, configured)
    any(node -> haskey(node, "preparation"), graph["nodes"]) &&
        throw(ArgumentError("Zemax component preparation requires AdaptiveOpticsSim and AdaptiveOpticsSimPipeWireHIL"))
    return graph
end
function controlled_actuators end

include("instruments/settings.jl")
include("instruments/geometry.jl")
include("instruments/influence_functions.jl")
include("instruments/schema.jl")
include("instruments/catalogs.jl")
include("instruments/spectra.jl")
include("instruments/dimensions.jl")
include("instruments/components.jl")
include("instruments/responses.jl")
include("instruments/masks.jl")
include("instruments/observations.jl")

function fields(value::AbstractDict, allowed, required, label)
    all(key -> key in allowed, keys(value)) && all(key -> haskey(value,key),required) ||
        throw(ArgumentError("invalid $label fields"))
    return value
end
fields(value, allowed, required, label) = throw(ArgumentError("$label must be an object"))

include("instruments/calibration.jl")

function bounded_yaml(path)
    document = Schemas.resolve(Common.read_yaml(path))
    InstrumentDefinition.bounded(document, Ref(131072))
    return document
end

"Read a physical instrument declaration without loading simulation or RTC configuration."
function load(path::AbstractString)
    document = bounded_yaml(path)
    declaration = (;path=abspath(path),directory=dirname(abspath(path)),document)
    validate_declaration(document,declaration.directory)
    return declaration
end

physical(declaration) = get(declaration, :instrument, declaration)

function referenced_instrument(path, reference)
    InstrumentDefinition.nonempty_text(reference) && !isabspath(reference) && !occursin('\0', reference) ||
        throw(ArgumentError("instrument reference must be a relative filename"))
    instrument = load(normpath(joinpath(dirname(abspath(path)), reference)))
    D.relative_asset(instrument.directory, relpath(abspath(path), instrument.directory))
    return instrument
end

function simulation_documents(path)
    authoring = bounded_yaml(path)
    document = deepcopy(authoring)
    fields(document, ("schema_version", "id", "instrument", "defaults", "settings_schema",
        "wire_contracts", "graphs", "preparation", "profiles", "bindings", "settings_bindings",
        "frame_period_s", "hil", "sensors", "sources", "components", "responses", "imaging", "observations", "optical_model"),
        ("schema_version", "id", "instrument", "defaults", "settings_schema",
        "profiles", "frame_period_s"), "simulation definition")
    haskey(document, "graphs") != haskey(document, "preparation") ||
        throw(ArgumentError("simulation definition must declare exactly one of graphs or preparation"))
    haskey(document, "hil") == haskey(document, "wire_contracts") ||
        throw(ArgumentError("simulation hil and wire_contracts must be declared together"))
    instrument = referenced_instrument(path, document["instrument"])
    if haskey(document, "optical_model")
        model = fields(document["optical_model"], ("format", "source"), ("format", "source"), "prepared optical model")
        model["format"] == "zemax" && haskey(document, "graphs") && !haskey(document, "hil") &&
            get(get(instrument.document, "optical_prescription", Dict()), "format", nothing) == "zemax" ||
            throw(ArgumentError("prepared optical model requires standalone Zemax execution graphs"))
        source = model["source"]
        source isa AbstractString && !isabspath(source) || throw(ArgumentError("optical model source must be relative"))
        resolved = D.relative_asset(instrument.directory, relpath(normpath(joinpath(dirname(abspath(path)), source)), instrument.directory))
        resolved == D.relative_asset(instrument.directory, "simulation/definition.yaml") ||
            throw(ArgumentError("optical model must identify its authored simulation/definition.yaml"))
        authored = bounded_yaml(resolved)
        get(get(authored, "preparation", Dict()), "kind", nothing) == "zemax" ||
            throw(ArgumentError("optical model requires an authored Zemax preparation source"))
    end
    return (; authoring, document, instrument)
end

function resolve_simulation_settings!(document, authoring, instrument)
    document["settings_schema"] = resolve_settings_schema(document["settings_schema"])
    profiles = _declaration_object(document["profiles"], "simulation profiles")
    1 <= length(profiles) <= 16 || throw(ArgumentError("simulation requires 1:16 profiles"))
    if shared_settings_schema(authoring["settings_schema"]) && haskey(document["settings_schema"]["properties"], "profile")
        document["settings_schema"]["properties"]["profile"]["enum"] = sort!(collect(keys(profiles)))
    end
    for profile in values(profiles)
        _declaration_object(profile, "simulation profile")
        if haskey(profile,"settings_schema")
            profile["settings_schema"] = resolve_profile_settings_schema(profile["settings_schema"])
        end
    end
    selection = authoring["settings_schema"]
    template = selection isa AbstractString ? selection : get(selection, "template", nothing)
    if template == "proper_optical_train"
        resolve_optical_settings_schema!(document, instrument.document;
            editable=haskey(document, "preparation") || haskey(document, "optical_model"))
    end
    return nothing
end

"Read an executable simulation definition and its shared physical instrument."
function load_simulation(path::AbstractString)
    (; authoring, document, instrument) = simulation_documents(path)
    if haskey(document, "preparation")
        load_simulation_source(path)
        throw(ArgumentError("authored simulation source requires preparation first; execute generated/simulation.yaml"))
    end
    expanded = expand_simulation_components!(document, instrument.document, instrument.directory)
    validate_observations(document, instrument.document, instrument.directory, expanded.graphs)
    expand_optical_mask_bindings!(document, instrument.document, expanded.graphs)
    resolve_simulation_settings!(document, authoring, instrument)
    validate_simulation(document, instrument.document, instrument.directory, expanded.graphs)
    return (;path=abspath(path),directory=instrument.directory,document,instrument,authoring,
        graphs=expanded.graphs,templates=expanded.templates)
end

"""Read authored simulation metadata before any generated optical model exists.

Prepared optical sources support settings profiles and bindings. Components,
profile nodes/parameters and settings bindings require declared authored response
graphs in `observations`; responses, sensors and sources remain empty. Imaging is
unsupported. Zemax conversion and execution belong to the scientific preparation
tool and generated/simulation.yaml. Expanded authored responses are returned as
`observation_graphs`, independently of the generated optical graphs.
Graph-bearing authored definitions retain the ordinary executable loader contract.
"""
function load_simulation_source(path::AbstractString)
    (; authoring, document, instrument) = simulation_documents(path)
    haskey(document, "preparation") || return load_simulation(path)
    preparation = _declaration_fields(document["preparation"], ("kind", "recipe"),
        ("kind", "recipe"), "simulation preparation")
    preparation["kind"] == "zemax" || throw(ArgumentError("unsupported simulation preparation kind"))
    prescription = get(instrument.document, "optical_prescription", Dict())
    get(prescription, "format", nothing) == preparation["kind"] ||
        throw(ArgumentError("simulation preparation must match the physical optical prescription format"))
    paths = _declaration_object(get(instrument.document, "optical_paths", Dict()), "physical optical paths")
    isempty(paths) && throw(ArgumentError("prepared optical source requires physical optical_paths"))
    recipe = _declaration_text(preparation["recipe"], "simulation preparation recipe")
    !isabspath(recipe) && !occursin('\0', recipe) ||
        throw(ArgumentError("simulation preparation recipe must be a relative filename"))
    recipe_candidate = joinpath(dirname(abspath(path)), recipe)
    isfile(recipe_candidate) || throw(ArgumentError("simulation preparation recipe must be an existing file"))
    preparation_path = D.relative_asset(instrument.directory,
        relpath(recipe_candidate, instrument.directory))
    relative_recipe = relpath(preparation_path, realpath(instrument.directory))
    "generated" in splitpath(relative_recipe) &&
        throw(ArgumentError("simulation preparation recipe must be an authored asset outside generated"))
    haskey(document, "hil") && throw(ArgumentError("prepared optical source does not support HIL execution"))
    for key in ("responses", "sensors", "sources")
        isempty(_declaration_object(get(document, key, Dict()), "simulation $key")) ||
            throw(ArgumentError("prepared optical source requires empty $key; declare execution graphs after preparation"))
    end
    haskey(document, "imaging") && throw(ArgumentError("prepared optical source does not support imaging"))
    bindings = _declaration_object(get!(document, "bindings", Dict{String,Any}()), "simulation bindings")
    entries = _declaration_array(get!(document, "settings_bindings", Any[]), "settings_bindings")
    resolve_simulation_settings!(document, authoring, instrument)
    validate_simulation_common(document, instrument.document)
    response_sources = observation_sources(document, instrument.document, instrument.directory)
    observation_graphs, templates = Dict{String,Any}(), ()
    if isempty(response_sources)
        isempty(_declaration_object(get(document, "components", Dict()), "simulation components")) ||
            throw(ArgumentError("prepared optical source components require declared observations"))
        isempty(entries) || throw(ArgumentError("prepared optical source requires empty settings_bindings without observations"))
        for (name, profile) in document["profiles"]
            _declaration_object(profile, "simulation profile")
            for key in ("nodes", "parameters")
                isempty(_declaration_array(get(profile, key, nothing), "profile $name $key")) ||
                    throw(ArgumentError("prepared optical source requires empty profile $key without observations"))
            end
        end
        _validate_profiles(document["profiles"], bindings, Set{String}())
        _validate_bindings(bindings, instrument.document["deformable_mirrors"], document["defaults"],
            document["settings_schema"], document["profiles"], instrument.directory)
    else
        response_document = deepcopy(document)
        response_document["graphs"] = response_sources
        expanded = expand_simulation_components!(response_document, instrument.document, instrument.directory)
        validate_simulation(response_document, instrument.document, instrument.directory, expanded.graphs)
        validate_observations(response_document, instrument.document, instrument.directory, expanded.graphs; source=true)
        for binding in values(response_document["bindings"])
            binding["kind"] == "fits" || continue
            haskey(binding, "sha256") || throw(ArgumentError("authored observations require SHA-256 for each FITS binding"))
        end
        for key in ("bindings", "settings_bindings", "profiles")
            document[key] = response_document[key]
        end
        observation_graphs, templates = expanded.graphs, expanded.templates
    end
    declaration = (;path=abspath(path),directory=instrument.directory,document,instrument,authoring,preparation_path,
        observation_graphs,templates)
    configured = settings(declaration)
    if !isempty(response_sources)
        for binding in values(document["bindings"])
            binding["kind"] == "fits" && binding_values(declaration, configured, binding)
        end
    end
    return declaration
end

"Read RTC dimensions and mirror-control definitions independently of the simulator."
function load_rtc(path::AbstractString)
    authoring = bounded_yaml(path)
    document = deepcopy(authoring)
    fields(document, ("schema_version", "instrument", "dimensions", "controller", "mirror_controls", "publication", "calibration_identity", "calibration"),
        ("schema_version", "instrument", "dimensions", "mirror_controls", "publication", "calibration_identity"), "RTC configuration")
    document["schema_version"] === 1 || throw(ArgumentError("unsupported RTC configuration schema"))
    _declaration_text(document["publication"], "RTC publication")
    _declaration_text(document["calibration_identity"], "RTC calibration identity")
    instrument = referenced_instrument(path, document["instrument"])
    isempty(instrument.document["deformable_mirrors"]) &&
        throw(ArgumentError("RTC configuration requires at least one deformable mirror"))
    document["dimensions"] = controller_dimensions(authoring, instrument)
    control_authoring = bounded_yaml(D.relative_asset(instrument.directory, document["mirror_controls"]))
    controls = deepcopy(control_authoring)
    fields(controls, ("schema_version", "deformable_mirrors"),
        ("schema_version", "deformable_mirrors"), "mirror controls")
    controls["schema_version"] === 1 || throw(ArgumentError("unsupported mirror control schema"))
    mirrors = _declaration_object(controls["deformable_mirrors"], "mirror controls")
    Set(keys(mirrors)) == Set(keys(instrument.document["deformable_mirrors"])) ||
        throw(ArgumentError("RTC mirror controls must name each instrument mirror exactly once"))
    for (name, control) in mirrors
        fields(control, ("limiter", "shape_control"), ("limiter", "shape_control"), "mirror control $name")
        _validate_limiter(control["limiter"])
        shape = _declaration_fields(control["shape_control"], ("bases", "controlled_actuators"), ("bases",), "shape_control")
        bases = _declaration_array(shape["bases"], "bases")
        length(bases) <= 16 || throw(ArgumentError("shape_control requires at most 16 bases"))
        shape["bases"] = [resolve_basis_definition(basis) for basis in bases]
        _validate_shape_control(control["shape_control"],
            instrument.document["deformable_mirrors"][name]["units"], instrument.directory)
    end
    calibration = if haskey(document, "calibration")
        calibration_path = D.relative_asset(instrument.directory, document["calibration"])
        context = bounded_yaml(calibration_path)
        _declaration_object(context, "RTC calibration context")
        calibration_context(context, dirname(calibration_path))
    else
        Dict{String,Any}()
    end
    return (;path=abspath(path),directory=instrument.directory,document,instrument,controls,calibration,authoring,control_authoring)
end

"Merge the declared defaults and validate the selected profile's startup settings."
function settings(declaration::NamedTuple, overrides::AbstractDict=Dict{String,Any}())
    document = declaration.document
    profile = get(overrides,"profile",get(document["defaults"],"profile",nothing))
    haskey(document["profiles"],profile) || throw(ArgumentError("unsupported instrument profile $profile"))
    schema = deepcopy(document["settings_schema"])
    merge!(schema["properties"],get(document["profiles"][profile],"settings_schema",Dict()))
    result = merge_settings(document["defaults"],overrides,schema)
    # Standalone optical prescriptions may contain generated coefficients.
    # Read-only settings must remain tied to the authored defaults and graphs.
    current = haskey(document, "hil") ? result : document["defaults"]
    validate_settings(schema,result,current)
    validate_optical_spectra(result, physical(declaration).document)
    paths = haskey(document, "preparation") ? keys(physical(declaration).document["optical_paths"]) :
        optical_graph_names(document, physical(declaration).document, keys(declaration.graphs))
    selected_optical_mask_responses(document, physical(declaration).document, paths, result)
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

# Source instruments may share mirror descriptions in a sibling mirrors directory.
# All other assets retain the application-relative boundary.
function mirror_description_path(directory, name::AbstractString)
    if startswith(name, "../mirrors/")
        return D.relative_asset(joinpath(dirname(directory), "mirrors"), name[12:end])
    end
    return D.relative_asset(directory, name)
end
mirror_description_path(directory, name) = D.relative_asset(directory, name)

function mirror(declaration, configured, name)
    instrument = physical(declaration)
    spec = instrument.document["deformable_mirrors"][name]
    description = read_mirror_description(mirror_description_path(instrument.directory,spec["description"]))
    registration = _pupil_registration(_instrument_seal(spec["pupil_registration"]))
    _require_pupil_geometry(description,registration)
    return (; description, registration)
end

"Build the cold reference context from selected settings and physical mirror descriptions."
function configuration_context(declaration, configured)
    instrument = deepcopy(physical(declaration).document)
    for (name, spec) in instrument["deformable_mirrors"]
        geometry = mirror(declaration, configured, name)
        spec["actuator_count"] = command_count(geometry.description)
        spec["actuator_axis_count"] = _mirror_axis_count(geometry.description)
        spec["grid_shape"] = collect(geometry.description.layout.grid_shape)
        spec["description_json"] = InstrumentDefinition.mirror_description_json(
            mirror_description_path(declaration.directory, spec["description"]))
    end
    for sensor in values(instrument["wavefront_sensors"])
        if haskey(sensor, "detector_shape")
            rows, columns = sensor["detector_shape"]
            # SPA's packed-video construction property is width x height.
            sensor["video_frame_size"] = string(columns, 'x', rows)
        end
        if haskey(sensor, "acquisition")
            acquisition = sensor["acquisition"]
            seconds = acquisition["exposure_duration_s"]
            acquisition["exposure_ns"] = round(UInt64, seconds * 1e9)
            acquisition["exposure_us"] = seconds * 1e6
        end
    end
    context = Dict("instrument" => instrument, "schemas" => Schemas.CATALOG)
    if haskey(declaration.document, "frame_period_s")
        simulation = deepcopy(declaration.document)
        period_ns = round(UInt64, Float64(Float32(simulation["frame_period_s"])) * 1e9)
        period_ns > 0 || throw(ArgumentError("simulation frame period rounds to zero nanoseconds"))
        rate = round(Int, 1e9 / period_ns)
        1 <= rate <= 1_000_000_000 &&
            UInt64(div(1_000_000_000 + div(rate, 2), rate)) == period_ns ||
            throw(ArgumentError("simulation frame period must agree with an integer transport rate"))
        simulation["rate"] = rate
        simulation["frame_period_ns"] = period_ns
        context["simulation"] = simulation
        context["settings"] = deepcopy(configured)
    end
    return context
end

transform(value, entry) = transform(Val(Symbol(get(entry,"transform","identity"))),value,entry)
transform(::Val{:identity}, value, entry) = deepcopy(value)
function transform(::Val{:reciprocal}, value::Real, entry)
    isfinite(value) && value > 0 || throw(ArgumentError("reciprocal setting must be finite and positive"))
    number = Float32(value)
    isfinite(number) && number > 0 || throw(ArgumentError("reciprocal setting must be finite and positive as Float32"))
    reciprocal = inv(number)
    isfinite(reciprocal) && reciprocal > 0 || throw(ArgumentError("setting reciprocal must be finite and positive as Float32"))
    return reciprocal
end
transform(::Val{:reciprocal}, ::Bool, entry) = throw(ArgumentError("reciprocal setting must not be Bool"))
transform(::Val{:reciprocal}, value, entry) = throw(ArgumentError("reciprocal setting must be a real number"))
function transform(::Val{:gaussian_width}, value, entry)
    pitch = _influence_number(value,"Gaussian actuator pitch")
    coupling = _influence_number(entry["coupling"],"Gaussian mechanical coupling")
    pitch > 0 && 0 < coupling < 1 || throw(ArgumentError("invalid Gaussian pitch/coupling"))
    width = pitch / sqrt(-2 * log(coupling))
    isfinite(Float32(width)) && Float32(width) > 0 || throw(ArgumentError("invalid Float32 Gaussian width"))
    return width
end
transform(kind::Val, value, entry) = throw(ArgumentError("unknown instrument settings transform $kind"))

"""
    graph_document(declaration, configured; calibration=false, simulation_graph=...)

Resolve profile and scalar settings into a declared AOS graph. The default is
`production`, or the ideal diagnostic `calibration` graph when `calibration=true`.
Explicitly declared `internal-source` and `dark` graphs retain normal component
settings. A dark graph must feed each detector's photon-rate input from an
explicit zero binding, without an optical link to that input. Unknown selections
reject before preparation.
"""
function graph_document(declaration, configured; calibration=false,
        simulation_graph=calibration ? "calibration" : "production")
    mode = simulation_graph
    mode isa AbstractString && haskey(declaration.graphs,mode) ||
        throw(ArgumentError("simulation graph is not declared"))
    calibration && mode != "calibration" && throw(ArgumentError("conflicting calibration graph selection"))
    graph = haskey(declaration.document, "optical_model") &&
        haskey(get(declaration.instrument.document, "optical_paths", Dict()), mode) ?
        optical_graph_document(declaration, configured, mode) : deepcopy(declaration.graphs[mode])
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
    for root in values(declaration.graphs)
        union!(all_names,(node["name"] for node in root["nodes"]))
    end
    for entry in declaration.document["settings_bindings"]
        fields(entry,("setting","value","nodes","config","profiles","transform","coupling"),
            ("nodes",),"settings binding")
        all(name -> name in all_names,entry["nodes"]) || throw(ArgumentError("settings binding names an absent graph node"))
        profile_name in get(entry,"profiles",[profile_name]) || continue
        input = haskey(entry, "setting") ? setting(configured,entry["setting"]) :
            Common.configuration_value(entry["value"], configuration_context(declaration, configured))
        value = transform(input,entry)
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
    hil = haskey(declaration.document, "hil")
    ideal = hil && mode == "calibration"
    graph["name"] = ideal ? graph["name"] : graph["name"] * "_" * profile_name
    resolved = Common.configuration_value(graph, configuration_context(declaration, configured))
    prepare_optical_components!(resolved, declaration, configured)
    ideal || apply_responses!(resolved, declaration, configured)
    hil && mode == "dark" && validate_dark_graph(resolved, declaration.document["bindings"])
    return resolved
end

function validate_dark_graph(graph, bindings)
    detectors = filter(node -> node["type"] == "detector", graph["nodes"])
    isempty(detectors) && throw(ArgumentError("dark graph requires a detector"))
    for detector in detectors
        destination = detector["name"] * ".photon_rate"
        any(link -> link["destination"] == destination, get(graph,"links",())) &&
            throw(ArgumentError("dark detector cannot receive an optical photon-rate link"))
        inputs = filter(input -> input["destination"] == destination, graph["inputs"])
        length(inputs) == 1 || throw(ArgumentError("dark detector requires one blocked photon-rate input"))
        binding = bindings[only(inputs)["binding"]]
        binding["kind"] == "zeros" && binding["type"] == "Float32" ||
            throw(ArgumentError("dark photon rate requires an explicit Float32 zero binding"))
    end
    return nothing
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
    prepared = Artifacts.prepare(source,T,Tuple(binding["shape"]))
    haskey(binding, "sha256") && prepared.provenance["original_sha256"] != binding["sha256"] &&
        throw(ArgumentError("FITS binding SHA-256 mismatch"))
    return prepared.data
end
binding_values(kind::Val,declaration,configured,binding) = throw(ArgumentError("unknown instrument binding kind $kind"))

include("instruments/metadata.jl")

end
