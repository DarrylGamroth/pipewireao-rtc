"""Cold, sealed instrument metadata published by the native RTC session."""
module InstrumentDefinition

import JSON, SHA
import ..Common
import ..DeploymentConfiguration

const PROPERTY = "pipewireao.rtc.session.instrument"
const HASH_PROPERTY = PROPERTY * ".sha256"
const MAX_BYTES = 1024 * 1024
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
        get(document,"schema_version",nothing)===2 || throw(ArgumentError("expected instrument definition schema version 2"))
    bounded(document)
    ncodeunits(JSON.json(document)) <= MAX_BYTES || throw(ArgumentError("instrument definition exceeds 1 MiB"))
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
        mirror_layout(layout,length(positions))
        if haskey(mirror,"pupil_coordinates")
            validate_pupil_coordinates(mirror["pupil_coordinates"],length(positions))
        end
        if haskey(mirror,"pupil")
            haskey(mirror,"pupil_coordinates") ||
                throw(ArgumentError("instrument optical pupil requires registered pupil coordinates"))
            validate_pupil(mirror["pupil"])
        end
        units = get(mirror,"units",nothing)
        nonempty_text(units) || throw(ArgumentError("instrument mirror requires command units"))
        validate_shape_control(get(mirror,"shape_control",nothing),units,length(positions))
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

# Basis definitions are cold descriptors. Numerical sampling of builtin bases
# belongs to the scientific consumer, not to RTC publication.
function exact_fields(value, names, label)
    object_value(value) && Set(keys(value)) == Set(names) || throw(ArgumentError("invalid $label fields"))
    return value
end

"Validate a centered optical pupil in the registered normalized-pupil coordinates."
function validate_pupil(pupil)
    exact_fields(pupil,("outer_radius","inner_radius"),"optical pupil")
    outer,inner = pupil["outer_radius"],pupil["inner_radius"]
    renderable_pupil_value(outer) && renderable_pupil_value(inner) && 0 <= inner < outer &&
        0 <= Float32(inner) < Float32(outer) ||
        throw(ArgumentError("optical pupil radii must be finite, nonnegative, ordered and distinct in Float32, with a positive outer radius"))
    return nothing
end

# Leave headroom for the GUI's Float32 viewport arithmetic, and preserve
# nonzero values through its conversion without changing the owned metadata.
renderable_pupil_value(value) = finite_bound(value) &&
    abs(value) < Float64(floatmax(Float32)) / 4 && (value == 0 || Float32(value) != 0)

function validate_pupil_coordinates(coordinates,count)
    array_value(coordinates) && length(coordinates) == count &&
        all(coordinates) do position
            array_value(position) && length(position) == 2 &&
                all(renderable_pupil_value,position)
        end || throw(ArgumentError("pupil coordinates must be finite Float32 x/y pairs in command order"))
    return nothing
end

bounded_text(value) = nonempty_text(value) && ncodeunits(value) <= 128
integer_value(value::Integer) = true
integer_value(::Bool) = false
integer_value(value) = false

function basis_header(basis, units)
    exact_fields(basis,("id","name","units","coefficient_limit","normalization","definition"),"basis")
    identifier(basis["id"]) || throw(ArgumentError("invalid basis id"))
    bounded_text(basis["name"]) || throw(ArgumentError("invalid basis name"))
    basis["units"] == units || throw(ArgumentError("basis units must match mirror command units"))
    positive_scale(basis["coefficient_limit"]) && positive_scale(Float32(basis["coefficient_limit"])) ||
        throw(ArgumentError("basis coefficient_limit must be positive and finite Float32"))
    definition = basis["definition"]
    object_value(definition) || throw(ArgumentError("basis definition must be an object"))
    kind = get(definition,"kind",nothing)
    normalization = kind == "zernike" ? "sampled_peak" : kind == "fourier" ? "sampled_rms" : kind == "sampled" ? "supplied" : nothing
    normalization !== nothing && basis["normalization"] == normalization ||
        throw(ArgumentError("invalid basis kind or normalization"))
    return definition
end

function basis_names(modes, maximum, label)
    array_value(modes) && 1 <= length(modes) <= maximum || throw(ArgumentError("$label requires 1:$maximum modes"))
    names = Set{String}()
    for mode in modes
        object_value(mode) && bounded_text(get(mode,"name",nothing)) || throw(ArgumentError("invalid $label mode name"))
        mode["name"] in names && throw(ArgumentError("duplicate $label mode name"))
        push!(names,mode["name"])
    end
    return nothing
end

function zernike_modes(modes)
    basis_names(modes,64,"Zernike")
    orders = Set{Tuple{Int,Int}}()
    for mode in modes
        exact_fields(mode,("name","n","m"),"Zernike mode")
        n,m = mode["n"],mode["m"]
        integer_value(n) && integer_value(m) && 0 <= n <= 12 && -n <= m <= n && iseven(n-m) ||
            throw(ArgumentError("invalid Zernike radial or azimuthal order"))
        (n,m) in orders && throw(ArgumentError("duplicate Zernike order"))
        push!(orders,(n,m))
    end
    return nothing
end

function basis_positions(positions, count, bound; float32=false)
    array_value(positions) && length(positions) == count || throw(ArgumentError("basis positions must be command-sized"))
    occupied = Set{Tuple{Float64,Float64}}()
    for position in positions
        array_value(position) && length(position) == 2 && all(x -> finite_bound(x) && abs(x) <= bound,position) ||
            throw(ArgumentError("invalid basis coordinates"))
        pair = Tuple(float32 ? Float64(Float32(x)) : Float64(x) for x in position)
        pair in occupied && throw(ArgumentError("duplicate basis coordinates"))
        push!(occupied,pair)
    end
    return nothing
end

function validate_shape_control(shape, units, count)
    object_value(shape) && haskey(shape,"bases") &&
        all(key -> key in ("bases","controlled_actuators"),keys(shape)) ||
        throw(ArgumentError("invalid shape_control fields"))
    if haskey(shape,"controlled_actuators")
        mask = shape["controlled_actuators"]
        array_value(mask) && length(mask)==count && all(value -> value === true || value === false,mask) ||
            throw(ArgumentError("controlled_actuators must be a command-sized boolean mask"))
    end
    bases = shape["bases"]
    array_value(bases) && length(bases) <= 16 || throw(ArgumentError("shape_control requires at most 16 bases"))
    !isempty(bases) && haskey(shape,"controlled_actuators") && !any(shape["controlled_actuators"]) &&
        throw(ArgumentError("shape bases require at least one controlled actuator"))
    ids = Set{String}()
    for basis in bases
        definition = basis_header(basis,units)
        basis["id"] in ids && throw(ArgumentError("duplicate basis id"))
        push!(ids,basis["id"])
        kind = definition["kind"]
        if kind == "zernike"
            exact_fields(definition,("kind","positions","modes"),"Zernike definition")
            basis_positions(definition["positions"],count,1.0)
            zernike_modes(definition["modes"])
        elseif kind == "fourier"
            exact_fields(definition,("kind","positions","frequencies","axis_units"),"Fourier definition")
            basis_positions(definition["positions"],count,0.5;float32=true)
            bounded_text(definition["axis_units"]) || throw(ArgumentError("invalid Fourier axis_units"))
            frequencies = definition["frequencies"]
            array_value(frequencies) && 1 <= length(frequencies) <= 256 || throw(ArgumentError("Fourier definition requires 1:256 frequencies"))
            occupied = Set{Tuple{Int,Int}}()
            for frequency in frequencies
                array_value(frequency) && length(frequency) == 2 && all(integer_value,frequency) || throw(ArgumentError("invalid Fourier wavevector"))
                x,y = frequency
                -64 <= x <= 64 && 0 <= y <= 64 && (y > 0 || x > 0) || throw(ArgumentError("invalid Fourier wavevector"))
                pair = (Int(x),Int(y))
                pair in occupied && throw(ArgumentError("duplicate Fourier wavevector"))
                push!(occupied,pair)
            end
        else
            exact_fields(definition,("kind","modes","artifact_sha256"),"sampled definition")
            hash = definition["artifact_sha256"]
            nonempty_text(hash) && occursin(r"^[0-9a-f]{64}$",hash) || throw(ArgumentError("invalid sampled artifact_sha256"))
            basis_names(definition["modes"],64,"sampled")
            for mode in definition["modes"]
                exact_fields(mode,("name","values"),"sampled mode")
                values = mode["values"]
                array_value(values) && length(values) == count && all(x -> finite_bound(x) && isfinite(Float32(x)),values) &&
                    any(x -> Float32(x) != 0,values) || throw(ArgumentError("sampled modes must be finite, nonzero and command-sized"))
            end
        end
    end
    return nothing
end

function load(path::AbstractString)
    isfile(path) && filesize(path)<=MAX_BYTES || throw(ArgumentError("instrument definition exceeds 1 MiB or is absent"))
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

grid_index(value::Integer, upper) = 1<=value<=upper
grid_index(::Bool, upper) = false
grid_index(value, upper) = false
function grid_pair(value::AbstractVector, bounds)
    length(value)==2 && all(grid_index.(value,bounds)) ||
        throw(ArgumentError("mirror grid coordinates must be bounded positive integers"))
    return (Int(value[1]),Int(value[2]))
end
grid_pair(value,bounds) = throw(ArgumentError("mirror grid coordinates require a pair"))
function mirror_layout(layout::AbstractDict, count)
    Set(keys(layout))==Set(("schema_version","name","grid_shape","axis_labels",
        "command_positions","command_order")) && layout["schema_version"]===1 ||
        throw(ArgumentError("expected mirror layout schema version 1"))
    for key in ("name","command_order")
        nonempty_text(layout[key]) || throw(ArgumentError("invalid mirror layout $key"))
    end
    labels=layout["axis_labels"]
    array_value(labels) && length(labels)==2 && all(nonempty_text,labels) ||
        throw(ArgumentError("mirror layout requires two axis labels"))
    shape=grid_pair(layout["grid_shape"],(4096,4096))
    positions=layout["command_positions"]
    array_value(positions) && 1<=length(positions)<=16384 && length(positions)==count ||
        throw(ArgumentError("mirror layout command count differs"))
    coordinates=map(position->grid_pair(position,shape),positions)
    length(Set(coordinates))==count || throw(ArgumentError("duplicate mirror command positions"))
    return nothing
end
mirror_layout(layout,count) = throw(ArgumentError("mirror layout requires an object"))

"Validate intrinsic mirror metadata independently of optical pupil registration."
function validate_mirror_description(description; command_count=nothing)
    object_value(description) || throw(ArgumentError("mirror description requires a JSON object"))
    bounded(description)
    required = Set(("schema_version", "id", "manufacturer", "model", "layout"))
    optional = Set(("actuator_pitch_m",))
    required ⊆ Set(keys(description)) ⊆ union(required, optional) &&
        description["schema_version"] === 1 ||
        throw(ArgumentError("expected mirror description schema version 1"))
    for key in ("id", "manufacturer", "model")
        nonempty_text(description[key]) || throw(ArgumentError("invalid mirror $key"))
    end
    if haskey(description, "actuator_pitch_m")
        pitch = description["actuator_pitch_m"]
        positive_scale(pitch) && positive_scale(Float64(pitch)) ||
            throw(ArgumentError("actuator_pitch_m must be finite and positive in metres"))
    end
    layout = description["layout"]
    object_value(layout) || throw(ArgumentError("mirror description requires a layout object"))
    positions = get(layout, "command_positions", nothing)
    array_value(positions) && 1 <= length(positions) <= 16384 ||
        throw(ArgumentError("mirror description requires a bounded positive command count"))
    count = command_count === nothing ? length(positions) : command_count
    mirror_layout(layout, count)
    return nothing
end

function _mirror_description(path::AbstractString)
    isvalid(path) && !isempty(path) && !occursin('\0', path) ||
        throw(ArgumentError("mirror description path must be a nonempty valid file path"))
    if lowercase(splitext(path)[2]) in (".yaml", ".yml")
        document = Common.read_yaml(path; maximum=64 * 1024)
        validate_mirror_description(document)
        document = Common.json_number(document)
        json = JSON.json(document)
        ncodeunits(json) <= 64 * 1024 || throw(ArgumentError("mirror description JSON exceeds 64 KiB"))
        return (; json, document)
    end
    isfile(path) || throw(ArgumentError("mirror description must be a regular file"))
    bytes = open(path) do io
        read(io, 64 * 1024 + 1)
    end
    length(bytes) <= 64 * 1024 || throw(ArgumentError("mirror description exceeds 64 KiB"))
    json = String(bytes)
    isvalid(json) || throw(ArgumentError("mirror description is not valid UTF-8"))
    # Preserve strict JSON transport and original publication bytes. Mirror
    # descriptions reject duplicate fields in both geometry and publication.
    token = strip(json, [' ', '\t', '\n', '\r'])
    startswith(token, "{") || throw(ArgumentError("mirror description requires a JSON object"))
    parsed = try
        JSON.parse(token; dicttype=Dict{String,Any}, duplicate_keys=:error, maxdepth=64)
    catch error
        throw(_mirror_json_error(error))
    end
    document = Common.json_number(parsed)
    validate_mirror_description(document)
    return (; json, document)
end

_mirror_json_error(error::JSON.DuplicateKeyError) = ArgumentError("duplicate mirror description field")
_mirror_json_error(error) = error

"Return JSON for device publication, compiling bounded YAML authoring when selected."
mirror_description_json(path::AbstractString) = _mirror_description(path).json

"Read the selected device description for ordinary simulated-mirror NodeInfo."
function mirror_properties(options)
    path = get(options,:mirror_description,nothing)
    path===nothing && return Dict{String,String}()
    (;json,document) = _mirror_description(path)
    description = document
    validate_mirror_description(description; command_count=options.command_count)
    if options.instrument!==nothing
        instrument = load(options.instrument).document
        mirrors = instrument["deformable_mirrors"]
        length(mirrors)==1 || throw(ArgumentError("this transport requires one mirror description"))
        description["layout"]==only(values(mirrors))["layout"] || throw(ArgumentError("mirror and instrument layouts differ"))
    end
    return Dict(MIRROR_PROPERTY=>json)
end

"Publish the intrinsic description for a named physical mirror command."
function mirror_properties(options, name::Symbol)
    options.version == 3 || return Dict{String,String}()
    declaration = getproperty(parentmodule(@__MODULE__), :InstrumentConfiguration)
    rtc = declaration.load_rtc(options.rtc_configuration)
    spec = get(rtc.instrument.document["deformable_mirrors"], string(name), nothing)
    spec === nothing && return Dict{String,String}()
    path = declaration.mirror_description_path(rtc.directory, spec["description"])
    (;json, document) = _mirror_description(path)
    validate_mirror_description(document; command_count=options.command_count[name])
    instrument = load(options.instrument).document
    document["layout"] == instrument["deformable_mirrors"][string(name)]["layout"] ||
        throw(ArgumentError("mirror and instrument layouts differ for $name"))
    return Dict(MIRROR_PROPERTY => json)
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
        mirror["shape_control"]==get(original,"shape_control",nothing) ||
            throw(ArgumentError("instrument DM basis declaration differs"))
        get(mirror,"pupil_coordinates",nothing)==get(original,"pupil_coordinates",nothing) || throw(ArgumentError("instrument pupil coordinates differ"))
        telescope = get(source,"telescope",Dict())
        pupil = haskey(original,"pupil") ? original["pupil"] :
            haskey(telescope,"central_obstruction_ratio") ?
                Dict("outer_radius"=>1.0,"inner_radius"=>telescope["central_obstruction_ratio"]) : nothing
        get(mirror,"pupil",nothing)==pupil || throw(ArgumentError("instrument optical pupil differs"))
    end
    for (name,sensor) in sensors
        original=source["wavefront_sensors"][name]["layout"]
        all(get(sensor["layout"],key,nothing)==value for (key,value) in original) || throw(ArgumentError("instrument WFS geometry differs"))
    end
    mirror_properties(options)
    return nothing
end


"Verify a configuration-built plant against its sealed RTC publication."
function verify_declaration(options)
    options.instrument === nothing && throw(ArgumentError("declarative plants require an instrument publication"))
    actual = load(options.instrument).document
    declaration = getproperty(parentmodule(@__MODULE__),:InstrumentConfiguration)
    expected = declaration.json_value(declaration.publication(options.rtc_configuration))
    actual == expected || throw(ArgumentError("instrument publication differs from its declaration or selected calibration"))
    simulation = declaration.load_simulation(options.plant.definition)
    rtc = declaration.load_rtc(options.rtc_configuration)
    options.calibration_identity == rtc.document["calibration_identity"] ||
        throw(ArgumentError("simulator calibration identity differs from the RTC configuration"))
    simulation.instrument.path == rtc.instrument.path ||
        throw(ArgumentError("simulator and RTC must reference the same physical instrument"))
    configured = declaration.settings(simulation, options.plant.settings)
    options.prescription_identity == declaration.prescription_identity(simulation, configured) ||
        throw(ArgumentError("simulation prescription differs from its prepared identity"))
    mirrors,sensors=actual["deformable_mirrors"],actual["wavefront_sensors"]
    length(sensors) == 1 || throw(ArgumentError("this AOS boundary requires one WFS"))
    wfs = only(values(sensors))
    verify_mirror_commands(mirrors, options.command_count, options.command_scale)
    Tuple(wfs["layout"]["detector_shape"]) == options.frame_shape || throw(DimensionMismatch("instrument WFS detector shape differs"))
    wfs["layout"]["expected_schema"] == options.frame_schema || throw(ArgumentError("instrument frame schema differs"))
    return nothing
end

function verify_mirror_commands(mirrors, count::Integer, scale::Real)
    length(mirrors) == 1 || throw(ArgumentError("a scalar AOS command requires one DM"))
    dm = only(values(mirrors))
    length(dm["layout"]["command_positions"]) == count || throw(DimensionMismatch("instrument DM command count differs"))
    Float32(dm["command_scale_m"]) == scale || throw(ArgumentError("instrument command scale differs"))
    return nothing
end
function verify_mirror_commands(mirrors, counts::NamedTuple, scales::NamedTuple)
    # Other named correctors (for example a tip/tilt OPD basis) are validated
    # against the typed scientific HIL boundary rather than invented DM geometry.
    all(name -> Symbol(name) in keys(counts), keys(mirrors)) ||
        throw(ArgumentError("every instrument mirror must have a matching named AOS command"))
    for (name, mirror) in mirrors
        key = Symbol(name)
        length(mirror["layout"]["command_positions"]) == counts[key] ||
            throw(DimensionMismatch("instrument DM command count differs for $name"))
        Float32(mirror["command_scale_m"]) == scales[key] ||
            throw(ArgumentError("instrument command scale differs for $name"))
    end
    return nothing
end

end
