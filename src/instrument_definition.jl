"""Cold, sealed instrument metadata published by the native RTC session."""
module InstrumentDefinition

import JSON, SHA
import ..Common
import ..DeploymentConfiguration

const PROPERTY = "pipewireao.rtc.session.instrument"
const HASH_PROPERTY = PROPERTY * ".sha256"
const MAX_BYTES = 256 * 1024
const MIRROR_PROPERTY = "device.mirror.description"
const D = DeploymentConfiguration
digest(json::AbstractString) = bytes2hex(SHA.sha256(codeunits(json)))
scientific_identity(value) = "sha256:" * digest(JSON.json(value))

function read_object(json)
    document=Common.parse_json(json)
    object_value(document) || throw(ArgumentError("expected exactly one JSON object"))
    return document
end

function bounded(value, remaining=Ref(65536), depth=0)
    remaining[] -= 1
    remaining[] >= 0 && depth <= 16 || throw(ArgumentError("instrument definition exceeds structural limits"))
    bound_value(value,remaining,depth)
    return nothing
end
function bound_value(value::AbstractDict,remaining,depth)
    for (key,item) in value
        valid_field_name(key) || throw(ArgumentError("invalid instrument field name"))
        bounded(item,remaining,depth+1)
    end
end
function bound_value(value::AbstractVector,remaining,depth)
    length(value)<=16384 || throw(ArgumentError("instrument array exceeds limit"))
    foreach(item -> bounded(item,remaining,depth+1),value)
end
function bound_value(value::String,remaining,depth)
    isvalid(value) && ncodeunits(value)<=16384 && !occursin('\0',value) || throw(ArgumentError("invalid instrument text"))
end
bound_value(value::Union{Bool,Nothing},remaining,depth) = nothing
function bound_value(value::Real,remaining,depth)
    isfinite(value) || throw(ArgumentError("instrument values must be finite JSON data"))
end
bound_value(value,remaining,depth) = throw(ArgumentError("instrument values must be finite JSON data"))
valid_field_name(key::String) = ncodeunits(key)<=128
valid_field_name(key) = false
object_value(value::AbstractDict) = true
object_value(value) = false
array_value(value::AbstractVector) = true
array_value(value) = false
nonempty_text(value::String) = !isempty(strip(value))
nonempty_text(value) = false
positive_scale(value::Real) = isfinite(value) && value > 0
positive_scale(::Bool) = false
positive_scale(value) = false
finite_bound(value::Real) = isfinite(value)
finite_bound(::Bool) = false
finite_bound(value) = false
identifier(value::String) = occursin(r"^[a-z][a-z0-9_.-]{0,127}$",value)
identifier(value) = false
sha_identity(value::String) = occursin(r"^sha256:[0-9a-f]{64}$",value)
sha_identity(value) = false
absolute_package(value::String) = isabspath(value)
absolute_package(value) = false
sealed_hash(value::String,expected) = value==expected
sealed_hash(value,expected) = false

function validate(document)
    object_value(document) && Set(keys(document))==Set(("schema_version","id",
        "calibration_identity","scientific_identity","deformable_mirrors","wavefront_sensors")) &&
        get(document,"schema_version",nothing)===1 || throw(ArgumentError("expected instrument definition schema version 1"))
    bounded(document)
    identifier(document["id"]) ||
        throw(ArgumentError("invalid instrument identifier"))
    for field in ("calibration_identity","scientific_identity")
        value=document[field]
        sha_identity(value) || throw(ArgumentError("instrument $field must be a SHA-256 identity"))
    end
    for family in ("deformable_mirrors","wavefront_sensors")
        components=document[family]
        object_value(components) && 1<=length(components)<=16 &&
            all(name -> occursin(r"^[a-z][a-z0-9_.-]{0,127}$",name),keys(components)) ||
            throw(ArgumentError("instrument requires bounded named components"))
    end
    for mirror in values(document["deformable_mirrors"])
        object_value(mirror) || throw(ArgumentError("instrument mirror must be an object"))
        layout = get(mirror, "layout", nothing)
        object_value(layout) || throw(ArgumentError("instrument mirror requires a layout"))
        positions = get(layout, "command_positions", nothing)
        array_value(positions) && !isempty(positions) ||
            throw(ArgumentError("instrument mirror requires ordered command positions"))
        scale = get(mirror, "command_scale_m", nothing)
        positive_scale(scale) ||
            throw(ArgumentError("instrument mirror requires a positive command scale"))
        limiter = get(mirror, "limiter", nothing)
        object_value(limiter) && get(limiter, "kind", nothing) == "amplitude" ||
            throw(ArgumentError("instrument mirror requires amplitude bounds"))
        lower, upper = get(limiter, "lower", nothing), get(limiter, "upper", nothing)
        array_value(lower) && array_value(upper) &&
            length(lower) == length(upper) == length(positions) &&
            all(zip(lower, upper)) do (lo, hi)
                finite_bound(lo) && finite_bound(hi) && lo < hi
            end || throw(ArgumentError("instrument amplitude bounds must be finite, ordered and command-sized"))
    end
    return document
end

function load(path::AbstractString)
    isfile(path) && filesize(path)<=MAX_BYTES || throw(ArgumentError("instrument definition exceeds 256 KiB or is absent"))
    json=read(path,String)
    isvalid(json) && !occursin('\0',json) || throw(ArgumentError("instrument definition is not valid UTF-8 JSON"))
    document=read_object(json)
    validate(document)
    return (;json,sha256=digest(json),document)
end

function publication(spec,bindings)
    haskey(spec,"instrument") || return Dict{String,String}()
    package=get(bindings,"PACKAGE",nothing)
    absolute_package(package) || throw(ArgumentError("instrument publication requires the installed application"))
    path=D.relative_asset(package,spec["instrument"])
    expected=get(get(spec,"artifacts",Dict()),spec["instrument"],nothing)
    definition=load(path)
    sealed_hash(expected,definition.sha256) || throw(ArgumentError("instrument publication is not sealed"))
    return Dict(PROPERTY=>definition.json,HASH_PROPERTY=>definition.sha256)
end

"Read the selected device description for ordinary simulated-mirror NodeInfo."
function mirror_properties(options)
    path = get(options,:mirror_description,nothing)
    path===nothing && return Dict{String,String}()
    options.instrument!==nothing || throw(ArgumentError("mirror description requires an instrument"))
    isfile(path) && filesize(path)<=64*1024 || throw(ArgumentError("mirror description exceeds 64 KiB or is absent"))
    json = read(path,String)
    isvalid(json) || throw(ArgumentError("mirror description is not UTF-8"))
    description = read_object(json)
    bounded(description)
    Set(keys(description))==Set(("schema_version","id","manufacturer","model","layout")) &&
        description["schema_version"]===1 || throw(ArgumentError("expected mirror description schema version 1"))
    for key in ("id","manufacturer","model")
        value=description[key]
        nonempty_text(value) || throw(ArgumentError("invalid mirror $key"))
    end
    instrument = load(options.instrument).document
    mirrors = instrument["deformable_mirrors"]
    length(mirrors)==1 || throw(ArgumentError("this transport requires one mirror description"))
    description["layout"]==only(values(mirrors))["layout"] || throw(ArgumentError("mirror and instrument layouts differ"))
    return Dict(MIRROR_PROPERTY=>json)
end

"Validate the scientific package and one-DM/one-WFS transport before execution."
function verify_plant(options,plant_module)
    options.instrument===nothing && return nothing
    definition=load(options.instrument).document
    isdefined(plant_module,:instrument_definition) || throw(ArgumentError("selected plant has no instrument definition API"))
    scientific=Base.invokelatest(getproperty(plant_module,:instrument_definition),options.plant.settings)
    definition["scientific_identity"]==scientific_identity(scientific) || throw(ArgumentError("scientific instrument definition differs from the selected RTC"))
    definition["id"]==scientific.id || throw(ArgumentError("instrument identity differs from the selected plant"))
    definition["calibration_identity"]==options.calibration_identity || throw(ArgumentError("instrument calibration identity differs from the selected plant"))
    mirrors,sensors=definition["deformable_mirrors"],definition["wavefront_sensors"]
    length(mirrors)==length(sensors)==1 || throw(ArgumentError("this AOS boundary requires one DM and one WFS"))
    dm,wfs=only(values(mirrors)),only(values(sensors))
    length(dm["layout"]["command_positions"])==options.command_count || throw(DimensionMismatch("instrument DM command count differs"))
    Tuple(wfs["layout"]["detector_shape"])==options.frame_shape || throw(DimensionMismatch("instrument WFS detector shape differs"))
    wfs["layout"]["expected_schema"]==options.frame_schema || throw(ArgumentError("instrument WFS schema differs"))
    Float32(dm["command_scale_m"])==options.command_scale || throw(ArgumentError("instrument DM command scale differs"))
    # Compare actual scientific fields as well as the fingerprint: a valid
    # identity must not authorize independently changed operational geometry.
    source=Common.parse_json(JSON.json(scientific))
    for (name,mirror) in mirrors
        original=source["deformable_mirrors"][name]
        mirror["layout"]==original["layout"] || throw(ArgumentError("instrument DM source-grid layout differs"))
        for family in ("zernike","fourier")
            get(mirror["shape_control"],family,nothing)==get(original,family,nothing) || throw(ArgumentError("instrument DM $family declaration differs"))
        end
        get(mirror,"pupil_coordinates",nothing)==get(original,"pupil_coordinates",nothing) || throw(ArgumentError("instrument pupil coordinates differ"))
    end
    for (name,sensor) in sensors
        original=source["wavefront_sensors"][name]["layout"]
        all(get(sensor["layout"],key,nothing)==value for (key,value) in original) || throw(ArgumentError("instrument WFS geometry differs"))
    end
    mirror_properties(options)
    return nothing
end

end
