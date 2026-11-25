"""Read authored simulation and calibration assets from existing instrument bundles."""
module AOSOwner

import ..Schemas

import TOML
import UUIDs

import ..Artifacts
import ..Common
using ..Common: reference_clock_configuration
import ..DeploymentConfiguration
import ..InstrumentDefinition
import ..InstrumentConfiguration

public configuration, requires_proper, load_instrument, plant_settings, plant_declaration

const MAX_RETAINED_BYTES = 512 * 1024 * 1024
const ELEMENT_TYPES = Dict(string(T) => T for T in Artifacts.TARGET_TYPES)

struct FITSBinding{T}
    binding::Symbol
    source::Artifacts.FITSArtifact
    element_type::Type{T}
    shape::Tuple{Vararg{Int}}
    function FITSBinding(binding, source, element_type, shape)
        T = convert(DataType, element_type)
        return new{T}(binding, source, T, shape)
    end
end

text(value, label) = throw(ArgumentError("$label must be a nonempty string"))
function text(value::String, label)
    !isempty(value) && ncodeunits(value) <= 16 * 1024 && !occursin('\0', value) ||
        throw(ArgumentError("$label must be a nonempty string"))
    return value
end
integer(value, label, lower, upper) =
    throw(ArgumentError("$label must be an integer in $lower:$upper"))
integer(value::Bool, label, lower, upper) = integer(nothing, label, lower, upper)
function integer(value::Integer, label, lower, upper)
    lower <= value <= upper ||
        throw(ArgumentError("$label must be an integer in $lower:$upper"))
    return Int(value)
end


pacing_period(value, rate) =
    throw(ArgumentError("pacing_rate_hz must be finite between zero and the model rate"))
pacing_period(value::Bool, rate) = pacing_period(nothing, rate)
function pacing_period(value::Real, rate)
    isfinite(value) && 0 <= value <= rate || throw(
        ArgumentError("pacing_rate_hz must be finite between zero and the model rate")
    )
    value == 0 && return Int64(0)
    return pacing_period_value(value)
end
pacing_period_value(value::Int) = Int64(div(1_000_000_000 + div(value, 2), value))
function pacing_period_value(value::Real)
    period = 1e9 / Float64(value)
    isfinite(period) && 1 <= period < Float64(typemax(Int64)) ||
        throw(ArgumentError("pacing period must fit signed Int64 nanoseconds"))
    return round(Int64, period)
end
function identifier(value, label)
    name = text(value, label)
    occursin(r"^[a-zA-Z_][a-zA-Z0-9_]*$", name) ||
        throw(ArgumentError("$label must be an identifier"))
    return Symbol(name)
end
function node_name(value, label)
    name = text(value, label)
    occursin(r"^[a-zA-Z0-9_.-]{1,128}$", name) || throw(ArgumentError("invalid $label"))
    return name
end
boolean(value::Bool, label) = value
boolean(value, label) = throw(ArgumentError("$label must be Boolean"))

"""
    plant_settings(value)

Seal a bounded JSON value into concrete, immutable cold settings.
"""
Base.@nospecializeinfer function plant_settings(
    @nospecialize(value), remaining = Ref(4096), depth = 0
)
    depth <= 16 || throw(ArgumentError("plant settings exceed 16 nesting levels"))
    remaining[] -= 1
    remaining[] >= 0 || throw(ArgumentError("plant settings exceed 4096 values"))
    return seal_plant_setting(value, remaining, depth)
end
function seal_plant_setting(value::AbstractDict, remaining, depth)
    length(value) <= remaining[] ||
        throw(ArgumentError("plant settings exceed 4096 values"))
    names = Tuple(identifier(key, "plant setting name") for key in keys(value))
    items = Tuple(plant_settings(item, remaining, depth + 1) for item in values(value))
    return NamedTuple{names}(items)
end
function seal_plant_setting(value::AbstractVector, remaining, depth)
    length(value) <= remaining[] ||
        throw(ArgumentError("plant settings exceed 4096 values"))
    return Tuple(plant_settings(item, remaining, depth + 1) for item in value)
end
function seal_plant_setting(value::String, remaining, depth)
    ncodeunits(value) <= 16 * 1024 && !occursin('\0', value) ||
        throw(ArgumentError("plant setting strings must be at most 16 KiB without NUL"))
    return value
end
seal_plant_setting(value::Union{Nothing,Bool,Integer}, remaining, depth) = value
function seal_plant_setting(value::AbstractFloat, remaining, depth)
    isfinite(value) || return seal_plant_setting(missing, remaining, depth)
    return value
end
seal_plant_setting(value, remaining, depth) =
    throw(ArgumentError("plant settings must contain finite basic JSON values"))

"""
    plant_declaration(value; directory=nothing)

Validate a dictionary containing exactly `package` and `settings`, and return
`(package, settings)` with settings sealed as nested named tuples and tuples.
If `directory` is supplied, resolve mirror-description and influence-function
paths as contained assets relative to it. This loads no scientific packages.
"""
plant_declaration(value; directory = nothing) =
    throw(ArgumentError("plant requires exactly package and settings"))
function plant_declaration(value::AbstractDict; directory = nothing)
    Set(keys(value)) == Set(("package", "settings")) ||
        throw(ArgumentError("plant requires exactly package and settings"))
    package = identifier(value["package"], "plant package")
    settings = plant_settings_object(value["settings"])
    if directory !== nothing && haskey(settings, :mirror_description)
        settings = merge(
            settings,
            (;
                mirror_description = DeploymentConfiguration.relative_asset(
                    directory, settings.mirror_description
                )
            ),
        )
    end
    if directory !== nothing &&
        haskey(settings, :influence_functions) &&
        hasproperty(settings.influence_functions, :path)
        influences = settings.influence_functions
        settings = merge(
            settings,
            (;
                influence_functions = merge(
                    influences,
                    (;
                        path = DeploymentConfiguration.relative_asset(
                            directory, influences.path
                        )
                    ),
                )
            ),
        )
    end
    return (; package, settings)
end

plant_settings_object(value::AbstractDict) = plant_settings(value)
plant_settings_object(value) = throw(ArgumentError("plant settings must be an object"))

# Version 3 can use the public HIL named-command boundary. All maps are
# sealed in the input declaration order before they reach execution ownership.
command_inputs(value::AbstractString) = identifier(value, "command_input")
function command_inputs(values::AbstractVector)
    1 <= length(values) <= 16 || throw(ArgumentError("command_input requires 1:16 names"))
    names = Tuple(identifier(value, "command_input") for value in values)
    length(unique(names)) == length(names) ||
        throw(ArgumentError("command_input names must be distinct"))
    return names
end
command_inputs(value) =
    throw(ArgumentError("command_input requires an identifier or array of identifiers"))

command_values(validate, value, ::Symbol, label) = validate(value, label)
function command_values(validate, value::AbstractDict, names::Tuple, label)
    Set(keys(value)) == Set(string.(names)) ||
        throw(ArgumentError("$label must name every command input exactly once"))
    return NamedTuple{names}(
        Tuple(validate(value[string(name)], "$label.$name") for name in names)
    )
end
command_values(validate, value, names::Tuple, label) =
    throw(ArgumentError("$label must name every command input exactly once"))
validate_command_inputs(version, ::Symbol) = nothing
function validate_command_inputs(version, ::Tuple)
    version == 3 || throw(ArgumentError("named command inputs require version 3"))
    return nothing
end

command_count(value, label) =
    integer(value, label, 1, Artifacts.MAX_IMAGE_BYTES ÷ sizeof(Float32))
function command_scale(value::Real, label)
    isfinite(value) && 0 < value <= floatmax(Float32) ||
        throw(ArgumentError("$label must be finite and positive"))
    scale = Float32(value)
    scale > 0 || throw(ArgumentError("$label underflows Float32"))
    return scale
end
command_scale(value::Bool, label) =
    throw(ArgumentError("$label must be finite and positive"))
command_scale(value, label) = throw(ArgumentError("$label must be finite and positive"))
command_shapes(count::Integer) = (count,)
command_shapes(counts::NamedTuple) = map(count -> (count,), counts)
command_items(value) = (value,)
command_items(values::NamedTuple) = Base.values(values)
command_names(name::Symbol) = (name,)
command_names(names::Tuple) = names

mirror_description(declaration, ::Tuple) = nothing
function mirror_description(declaration, ::Symbol)
    mirrors = declaration.instrument.document["deformable_mirrors"]
    return length(mirrors) == 1 ?
           DeploymentConfiguration.relative_asset(
        declaration.directory, only(values(mirrors))["description"]
    ) : nothing
end

"""
    configuration(path)

Validate every configuration declaration before preparing any FITS artifact.
"""
function configuration(path::AbstractString)
    document = DeploymentConfiguration.decode(
        path, get(ENV, "PIPEWIREAO_PREFIX", "/opt/pipewireao")
    )
    return configuration(path, document)
end
configuration(path, document) = throw(ArgumentError("AOS configuration must be an object"))
function configuration(path, document::AbstractDict)
    version = integer(get(document, "version", nothing), "version", 1, 6)
    version in (4, 6) && return external_pupil_configuration(path, document)
    version == 5 && return pupil_source_configuration(path, document)
    shared_fields = (
        "version",
        "command_input",
        "frame_output",
        "command_count",
        "frame_shape",
        "rate",
        "exposure_ns",
        "pacing_rate_hz",
        "backend",
        "device",
        "command_node",
        "frame_schema",
        "command_schema",
        "command_scale",
        "total_exchanges",
        "optical_observation",
        "detector_observation",
        "command_observation",
        "applied_command_observation",
        "calibration_identity",
        "instrument",
        "rtc_configuration",
        "prescription_identity",
        "reference_clock",
    )
    shared_required = (
        "version",
        "command_input",
        "frame_output",
        "command_count",
        "frame_shape",
        "rate",
        "exposure_ns",
        "pacing_rate_hz",
        "backend",
        "device",
    )
    route_fields = version == 1 ? ("graph", "artifacts") : ("plant", "frame_encoding")
    fields =
        version == 3 ? (shared_fields..., route_fields..., "pupil_output") :
        (shared_fields..., route_fields...)
    required =
        version == 1 ? (shared_required..., route_fields...) :
        (
            shared_required...,
            route_fields...,
            "frame_schema",
            "command_schema",
            "command_scale",
        )
    version == 3 && (
        required = (
            required...,
            "instrument",
            "calibration_identity",
            "rtc_configuration",
            "prescription_identity",
        )
    )
    all(key -> key in fields, keys(document)) &&
    all(key -> haskey(document, key), required) ||
        throw(ArgumentError("invalid AOS configuration fields"))
    config_path = abspath(path)
    graph =
        version == 1 ?
        abspath(joinpath(dirname(config_path), text(document["graph"], "graph"))) : nothing
    graph === nothing ||
        isfile(graph) ||
        throw(ArgumentError("AOS graph does not exist: $graph"))
    plant = if version == 3
        entry = document["plant"]
        InstrumentConfiguration.fields(
            entry,
            ("definition", "settings", "graph"),
            ("definition", "settings"),
            "declarative plant",
        )
        definition = DeploymentConfiguration.relative_asset(
            dirname(config_path), entry["definition"]
        )
        declaration = InstrumentConfiguration.load_simulation(
            definition; validate_optics = false
        )
        configured = InstrumentConfiguration.settings(declaration, entry["settings"])
        selected = InstrumentConfiguration.selected_graph(
            declaration, get(entry, "graph", "production")
        )
        selected == "calibration" && throw(
            ArgumentError(
                "the numerical calibration graph cannot be selected as a live simulator graph",
            ),
        )
        (; definition, graph = selected, settings = plant_settings(configured))
    elseif version == 2
        plant_declaration(document["plant"]; directory = dirname(config_path))
    else
        nothing
    end
    command_input = command_inputs(document["command_input"])
    validate_command_inputs(version, command_input)
    frame_output = identifier(document["frame_output"], "frame_output")
    command_count = command_values(
        AOSOwner.command_count, document["command_count"], command_input, "command_count"
    )
    sum(command_items(command_count)) <= Artifacts.MAX_IMAGE_BYTES ÷ sizeof(Float32) ||
        throw(ArgumentError("combined command storage exceeds the image byte limit"))
    frame_shape = Artifacts.checked_shape(document["frame_shape"], sizeof(Float32))
    length(frame_shape) == 2 ||
        throw(ArgumentError("AOS frame_shape must have two dimensions"))
    rate = integer(document["rate"], "rate", 1, 1_000_000_000)
    period_ns = UInt64(div(1_000_000_000 + div(rate, 2), rate))
    exposure_ns = UInt64(integer(document["exposure_ns"], "exposure_ns", 1, period_ns))
    pacing_rate_hz = document["pacing_rate_hz"]
    pacing_period_ns = pacing_period(pacing_rate_hz, rate)
    backend = Symbol(text(document["backend"], "backend"))
    backend in (:cpu, :cuda, :amdgpu) ||
        throw(ArgumentError("AOS backend must be cpu, cuda or amdgpu"))
    device = integer(document["device"], "device", 0, typemax(Int32))
    backend == :cpu && device != 0 && throw(ArgumentError("CPU backend requires device 0"))
    backend == :amdgpu &&
        device == 0 &&
        throw(ArgumentError("AMDGPU device identifiers start at 1"))
    command_node = command_values(
        node_name,
        get(document, "command_node", "simulator-command"),
        command_input,
        "command_node",
    )
    length(unique(command_items(command_node))) == length(command_items(command_node)) ||
        throw(ArgumentError("command node names must be distinct"))
    frame_encoding =
        version == 1 ? :uint16 : Symbol(text(document["frame_encoding"], "frame_encoding"))
    frame_encoding === :uint16 || throw(ArgumentError("AOS frame_encoding must be uint16"))
    frame_schema = text(
        get(document, "frame_schema", Schemas.identifier("raw_detector_pixels")),
        "frame_schema",
    )
    command_schema = command_values(
        text,
        get(document, "command_schema", Schemas.identifier("demanded_pdm_command")),
        command_input,
        "command_schema",
    )
    command_scale = command_values(
        AOSOwner.command_scale,
        get(document, "command_scale", 1.0f-6),
        command_input,
        "command_scale",
    )
    total = get(document, "total_exchanges", nothing)
    total_exchanges =
        total === nothing ? nothing :
        UInt64(integer(total, "total_exchanges", 1, typemax(Int64)))
    optical_observation = boolean(
        get(document, "optical_observation", false), "optical_observation"
    )
    pupil_output = boolean(get(document, "pupil_output", false), "pupil_output")
    if pupil_output
        declaration = InstrumentConfiguration.load_simulation(
            plant.definition; validate_optics = false
        )
        InstrumentConfiguration.pupil_output(
            declaration,
            InstrumentConfiguration.settings(declaration, plant.settings);
            simulation_graph = plant.graph,
        ) === nothing &&
            throw(ArgumentError("pupil_output requires a declared scientific pupil output"))
    end
    detector_observation = boolean(
        get(document, "detector_observation", false), "detector_observation"
    )
    command_observation = boolean(
        get(document, "command_observation", false), "command_observation"
    )
    applied_command_observation = boolean(
        get(document, "applied_command_observation", false), "applied_command_observation"
    )
    calibration_identity =
        haskey(document, "calibration_identity") ?
        text(document["calibration_identity"], "calibration_identity") : nothing
    instrument =
        haskey(document, "instrument") ?
        DeploymentConfiguration.relative_asset(
            dirname(config_path), document["instrument"]
        ) : nothing
    instrument === nothing ||
        version in (2, 3) && calibration_identity !== nothing ||
        throw(
            ArgumentError(
                "instrument definition requires an instrument plant and calibration identity",
            ),
        )
    rtc_configuration =
        version == 3 ?
        DeploymentConfiguration.relative_asset(
            dirname(config_path), document["rtc_configuration"]
        ) : nothing
    prescription_identity =
        version == 3 ? text(document["prescription_identity"], "prescription identity") :
        nothing
    mirror_description =
        plant === nothing ? nothing : get(plant.settings, :mirror_description, nothing)
    if version == 3
        declaration = InstrumentConfiguration.load_simulation(
            plant.definition; validate_optics = false
        )
        mirror_description = AOSOwner.mirror_description(declaration, command_input)
    end
    entries = version == 1 ? document["artifacts"] : ()
    entries = artifact_entries(entries)
    artifacts = FITSBinding[]
    names = Set(command_names(command_input))
    total_bytes = sum(command_items(command_count)) * sizeof(Float32)
    for entry in entries
        entry = artifact_entry(entry)
        binding = identifier(get(entry, "binding", nothing), "artifact binding")
        binding in names &&
            throw(ArgumentError("duplicate or command FITS binding $binding"))
        push!(names, binding)
        T = get(ELEMENT_TYPES, get(entry, "type", nothing), nothing)
        T === nothing && throw(ArgumentError("unsupported AOS FITS type"))
        shape = Artifacts.checked_shape(get(entry, "shape", nothing), sizeof(T))
        axes = get(entry, "axes", nothing)
        length(shape) > 1 &&
            axes === nothing &&
            throw(ArgumentError("multidimensional FITS bindings require axes"))
        source = Artifacts.FITSArtifact(
            joinpath(
                dirname(abspath(path)), text(get(entry, "path", nothing), "artifact path")
            );
            hdu = get(entry, "hdu", 1),
            axes,
        )
        source.axes === nothing ||
            length(source.axes) == length(shape) ||
            throw(DimensionMismatch("FITS axes and shape ranks differ"))
        total_bytes += prod(shape) * sizeof(T)
        total_bytes <= MAX_RETAINED_BYTES ||
            throw(ArgumentError("retained AOS bindings exceed 512 MiB"))
        push!(artifacts, FITSBinding(binding, source, T, shape))
    end
    return (;
        reference_clock = reference_clock_configuration(
            get(document, "reference_clock", nothing)
        ),
        version,
        config_path,
        plant,
        graph,
        command_input,
        frame_output,
        command_count,
        frame_shape,
        rate,
        period_ns,
        exposure_ns,
        pacing_rate_hz,
        pacing_period_ns,
        backend,
        device,
        artifacts,
        command_node,
        frame_encoding,
        frame_schema,
        command_schema,
        command_scale,
        total_exchanges,
        optical_observation,
        pupil_output,
        detector_observation,
        command_observation,
        applied_command_observation,
        calibration_identity,
        instrument,
        mirror_description,
        rtc_configuration,
        prescription_identity,
    )
end

artifact_entries(entries) =
    throw(ArgumentError("artifacts must be an array of at most 64 entries"))
artifact_entries(entries::Tuple{}) = entries
function artifact_entries(entries::AbstractVector)
    length(entries) <= 64 || return artifact_entries(nothing)
    return entries
end
artifact_entry(entry) = throw(ArgumentError("invalid AOS FITS binding fields"))
function artifact_entry(entry::AbstractDict)
    all(key -> key in ("binding", "path", "hdu", "axes", "type", "shape"), keys(entry)) ||
        return artifact_entry(nothing)
    return entry
end
"Prepare owned logical FITS arrays; preserve their provenance for the science owner."
function prepare_bindings(entries; check = () -> nothing)
    prepared = Artifacts.PreparedArtifact[]
    for entry in entries
        check()
        push!(
            prepared,
            Artifacts.prepare(entry.source, entry.element_type, entry.shape; check),
        )
    end
    check()
    return prepared
end

include("external_pupil_configuration.jl")
include("pupil_source_configuration.jl")

"""
    load_instrument(package)

Load only the exact plant dependency declared by the active application.
"""
function load_instrument(package::Symbol)
    project = Base.active_project()
    project !== nothing && isfile(project) || throw(
        ArgumentError("instrument preparation requires an active application Project.toml"),
    )
    dependencies = get(TOML.parsefile(project), "deps", nothing)
    name = string(package)
    identity = plant_dependency(dependencies, name)
    instrument = Base.require(identity)
    Base.PkgId(instrument) == identity || throw(
        ArgumentError("loaded plant module differs from the declared dependency identity"),
    )
    return instrument
end

plant_dependency(dependencies, name) = throw(
    ArgumentError(
        "plant package $name must be a direct dependency of the active application"
    ),
)
function plant_dependency(dependencies::AbstractDict, name)
    haskey(dependencies, name) || return plant_dependency(nothing, name)
    return plant_dependency_identity(dependencies[name], name)
end
plant_dependency_identity(uuid::String, name) = Base.PkgId(UUIDs.UUID(uuid), name)
plant_dependency_identity(uuid, name) =
    throw(ArgumentError("plant dependency $name must declare a UUID"))

"""
    requires_proper(options)

Return whether the selected simulator graphs require the Proper backend.
"""
function requires_proper(options)
    options.version in (3, 4, 5, 6) || return false
    # Node types decide whether Proper must load; generated optical provenance
    # is verified afterwards by the ordinary declaration/execution preparation.
    declaration = InstrumentConfiguration.load_simulation(
        options.plant.definition; validate_optics = false
    )
    configured = InstrumentConfiguration.settings(declaration, options.plant.settings)
    if options.version in (4, 6)
        names = collect(keys(declaration.instrument.document["optical_paths"]))
        append!(names, [row.unfringed_graph for row in values(options.plant.chopping)])
        options.version == 6 && push!(names, options.source_graph)
        return any(
            name -> InstrumentConfiguration.graph_requires_proper(
                declaration, configured; simulation_graph = name
            ),
            names,
        )
    end
    return InstrumentConfiguration.graph_requires_proper(
        declaration, configured; simulation_graph = get(options.plant, :graph, "production")
    )
end

end
