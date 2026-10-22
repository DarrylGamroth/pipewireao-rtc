"""Cold, sealed instrument metadata published by the native RTC session."""
module InstrumentDefinition

import JSON3, SHA
import ..DeploymentConfiguration

const PROPERTY = "pipewireao.rtc.session.instrument"
const HASH_PROPERTY = PROPERTY * ".sha256"
const MAX_BYTES = 256 * 1024
const D = DeploymentConfiguration
digest(json::AbstractString) = bytes2hex(SHA.sha256(codeunits(json)))
scientific_identity(value) = "sha256:" * digest(JSON3.write(value))

function bounded(value, remaining=Ref(65536), depth=0)
    remaining[] -= 1
    remaining[] >= 0 && depth <= 16 || throw(ArgumentError("instrument definition exceeds structural limits"))
    if value isa AbstractDict
        for (key,item) in value
            key isa String && ncodeunits(key)<=128 || throw(ArgumentError("invalid instrument field name"))
            bounded(item,remaining,depth+1)
        end
    elseif value isa AbstractVector
        length(value)<=16384 || throw(ArgumentError("instrument array exceeds limit"))
        foreach(item -> bounded(item,remaining,depth+1),value)
    elseif value isa String
        ncodeunits(value)<=16384 && !occursin('\0',value) || throw(ArgumentError("invalid instrument text"))
    elseif !(value isa Bool || value===nothing || value isa Real && isfinite(value))
        throw(ArgumentError("instrument values must be finite JSON data"))
    end
    return nothing
end

function validate(document)
    document isa AbstractDict && Set(keys(document))==Set(("schema_version","id",
        "calibration_identity","scientific_identity","deformable_mirrors","wavefront_sensors")) &&
        get(document,"schema_version",nothing)===1 || throw(ArgumentError("expected instrument definition schema version 1"))
    bounded(document)
    document["id"] isa String && occursin(r"^[a-z][a-z0-9_.-]{0,127}$",document["id"]) ||
        throw(ArgumentError("invalid instrument identifier"))
    for field in ("calibration_identity","scientific_identity")
        value=document[field]
        value isa String && occursin(r"^sha256:[0-9a-f]{64}$",value) || throw(ArgumentError("instrument $field must be a SHA-256 identity"))
    end
    for family in ("deformable_mirrors","wavefront_sensors")
        components=document[family]
        components isa AbstractDict && 1<=length(components)<=16 &&
            all(name -> occursin(r"^[a-z][a-z0-9_.-]{0,127}$",name),keys(components)) ||
            throw(ArgumentError("instrument requires bounded named components"))
    end
    for mirror in values(document["deformable_mirrors"])
        mirror isa AbstractDict || throw(ArgumentError("instrument mirror must be an object"))
        layout = get(mirror, "layout", nothing)
        layout isa AbstractDict || throw(ArgumentError("instrument mirror requires a layout"))
        positions = get(layout, "command_positions", nothing)
        positions isa AbstractVector && !isempty(positions) ||
            throw(ArgumentError("instrument mirror requires ordered command positions"))
        scale = get(mirror, "command_scale_m", nothing)
        scale isa Real && !(scale isa Bool) && isfinite(scale) && scale > 0 ||
            throw(ArgumentError("instrument mirror requires a positive command scale"))
        limiter = get(mirror, "limiter", nothing)
        limiter isa AbstractDict && get(limiter, "kind", nothing) == "amplitude" ||
            throw(ArgumentError("instrument mirror requires amplitude bounds"))
        lower, upper = get(limiter, "lower", nothing), get(limiter, "upper", nothing)
        lower isa AbstractVector && upper isa AbstractVector &&
            length(lower) == length(upper) == length(positions) &&
            all(zip(lower, upper)) do (lo, hi)
                lo isa Real && hi isa Real && !(lo isa Bool) && !(hi isa Bool) &&
                    isfinite(lo) && isfinite(hi) && lo < hi
            end || throw(ArgumentError("instrument amplitude bounds must be finite, ordered and command-sized"))
    end
    return document
end

function load(path::AbstractString)
    isfile(path) && filesize(path)<=MAX_BYTES || throw(ArgumentError("instrument definition exceeds 256 KiB or is absent"))
    json=read(path,String)
    isvalid(json) && !occursin('\0',json) || throw(ArgumentError("instrument definition is not valid UTF-8 JSON"))
    document=JSON3.read(json,Dict{String,Any})
    validate(document)
    return (;json,sha256=digest(json),document)
end

function publication(spec,bindings)
    haskey(spec,"instrument") || return Dict{String,String}()
    package=get(bindings,"PACKAGE",nothing)
    package isa String && isabspath(package) || throw(ArgumentError("instrument publication requires the installed application"))
    path=D.relative_asset(package,spec["instrument"])
    expected=get(get(spec,"artifacts",Dict()),spec["instrument"],nothing)
    definition=load(path)
    expected isa String && definition.sha256==expected || throw(ArgumentError("instrument publication is not sealed"))
    return Dict(PROPERTY=>definition.json,HASH_PROPERTY=>definition.sha256)
end

"Validate the scientific package and one-DM/one-WFS transport before execution."
function verify_plant(options,plant_module)
    options.instrument===nothing && return nothing
    definition=load(options.instrument).document
    isdefined(plant_module,:instrument_definition) || throw(ArgumentError("selected plant has no instrument definition API"))
    scientific=Base.invokelatest(getproperty(plant_module,:instrument_definition))
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
    source=JSON3.read(JSON3.write(scientific),Dict{String,Any})
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
    return nothing
end

end
