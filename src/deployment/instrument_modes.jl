_mode_fields(mode) = throw(ArgumentError("invalid application mode fields"))
_mode_fields(mode::AbstractDict) =
    Set(keys(mode)) ⊆
    Set(["extends", "application", "session", "core", "omit-views", "requires"]) ||
    throw(ArgumentError("invalid application mode fields"))
_mode_parent(parent) = throw(ArgumentError("mode extends must name a declared mode"))
_mode_parent(::AbstractString) = nothing
_mode_fragment(fragment, key) = throw(ArgumentError("mode $key must be an object"))
_mode_fragment(::AbstractDict, key) = nothing
_mode_devices(devices) =
    throw(ArgumentError("devices must be ordinary native owner declarations"))
_mode_devices(devices::AbstractVector) = foreach(_mode_device, devices)
_mode_device(device) =
    throw(ArgumentError("devices must be ordinary native owner declarations"))
_mode_device(::AbstractDict) = nothing
_mode_calibration(calibration) =
    throw(ArgumentError("calibration requires parameters and identity"))
_mode_calibration(calibration::AbstractDict) =
    Set(keys(calibration)) == Set(["parameters", "identity"]) ||
    throw(ArgumentError("calibration requires parameters and identity"))
_mode_calibration_identity(identity) =
    throw(ArgumentError("calibration identity must be nonempty"))
_mode_calibration_identity(identity::AbstractString) =
    !isempty(identity) || throw(ArgumentError("calibration identity must be nonempty"))

# Cold composition of ordinary application/session/core configuration fragments.
# There is no instrument identity or device plugin selection in this code.
function merge_configuration(
    base::AbstractDict, fragment::AbstractDict; replace_arrays = false
)
    result = deepcopy(base)
    for (key, value) in fragment
        result[key] =
            haskey(result, key) ? merge_configuration(result[key], value; replace_arrays) :
            deepcopy(value)
    end
    return result
end
merge_configuration(
    base::AbstractVector, fragment::AbstractVector; replace_arrays = false
) = replace_arrays ? deepcopy(fragment) : vcat(base, fragment)
merge_configuration(base, fragment; replace_arrays = false) = deepcopy(fragment)

function resolve_mode(modes, name, ancestors = String[])
    InstrumentDefinition.nonempty_text(name) && haskey(modes, name) ||
        throw(ArgumentError("unknown instrument application mode"))
    name in ancestors && throw(ArgumentError("application mode inheritance cycle"))
    length(ancestors) < 16 ||
        throw(ArgumentError("application mode inheritance exceeds 16 levels"))
    mode = deepcopy(modes[name])
    _mode_fields(mode)
    if haskey(mode, "extends")
        parent = pop!(mode, "extends")
        _mode_parent(parent)
        mode = merge_configuration(
            resolve_mode(modes, parent, [ancestors; name]), mode; replace_arrays = true
        )
    end
    for key in ("application", "session", "core")
        haskey(mode, key) && _mode_fragment(mode[key], key)
    end
    for key in ("omit-views", "requires")
        values = InstrumentConfiguration._declaration_array(get(mode, key, []), "mode $key")
        all(InstrumentDefinition.nonempty_text, values) ||
            throw(ArgumentError("mode $key must contain names"))
        key == "requires" &&
            !all(value -> value in ("devices", "calibration"), values) &&
            throw(ArgumentError("unknown application mode requirement"))
    end
    get!(mode, "application", Dict{String,Any}())
    return mode
end

function selected_mode(source, profile)
    path = joinpath(source, dirname(application_file(profile)), "modes.yaml")
    if !isfile(path)
        isempty(intersect(Set(keys(profile)), Set(["mode", "devices", "calibration"]))) ||
            throw(ArgumentError("instrument has no declared application modes"))
        return Dict("application" => Dict())
    end
    path = D.relative_asset(source, relpath(path, source))
    document = InstrumentConfiguration.bounded_yaml(path)
    Set(keys(document)) == Set(["default", "modes"]) ||
        throw(ArgumentError("invalid application modes fields"))
    modes = InstrumentConfiguration._declaration_object(
        document["modes"], "application modes"
    )
    1 <= length(modes) <= 64 || throw(ArgumentError("application requires 1:64 modes"))
    for name in keys(modes)
        resolve_mode(modes, name)
    end
    haskey(modes, document["default"]) ||
        throw(ArgumentError("unknown default application mode"))
    name = get(profile, "mode", document["default"])
    mode = resolve_mode(modes, name)
    for field in get(mode, "requires", [])
        field in ("devices", "calibration") ||
            throw(ArgumentError("unknown application mode requirement"))
        haskey(profile, field) ||
            throw(ArgumentError("selected mode requires explicit $field configuration"))
        profile[field] === nothing &&
            throw(ArgumentError("selected mode requires non-null $field configuration"))
    end
    devices = get(profile, "devices", [])
    _mode_devices(devices)
    "devices" in get(mode, "requires", []) &&
        isempty(devices) &&
        throw(ArgumentError("selected mode requires device owners"))
    return mode
end

function prepare_mode!(
    application,
    spec,
    mode,
    profile,
    bindings,
    prefix;
    configuration = "rtc/configuration.yaml",
)
    queue_inputs = D.PortAddress[]
    for (field, path) in (("session", spec["session"]), ("core", spec["core"]))
        fullpath = D.relative_asset(application, path)
        original = D.decode(fullpath, prefix)
        combined = merge_configuration(original, get(mode, field, Dict()))
        combined = substitute(combined, bindings)
        if field == "core"
            queue_inputs = queue_templates!(combined; metadata_defaults = false)
            telemetry_queues!(combined; metadata_defaults = false)
            validate_telemetry_groups(combined)
        end
        ScienceExport.write_spa_config(fullpath, combined)
    end
    calibration = get(profile, "calibration", nothing)
    if calibration !== nothing
        _mode_calibration(calibration)
        identity = calibration["identity"]
        _mode_calibration_identity(identity)
        selected = D.relative_asset(application, calibration["parameters"])
        document = Common.read_json(selected)
        # Parameter paths are relative to their binding file, not the application.
        destination = joinpath(application, "rtc", "parameters.conf")
        for parameter in document["parameters"]
            asset = normpath(joinpath(dirname(selected), parameter["path"]))
            relative = relpath(asset, application)
            D.relative_asset(application, relative)
            parameter["path"] = relpath(asset, dirname(destination))
        end
        Common.write_json(destination, document)
        configuration_path = D.relative_asset(application, configuration)
        rtc = Common.read_yaml(configuration_path)
        rtc["calibration_identity"] = identity
        Common.write_yaml(
            configuration_path,
            rtc;
            atomic = true,
            header = "Generated by PipeWireAORTC from RTC source and selected calibration.",
        )
    end
    omitted = get(mode, "omit-views", [])
    if !isempty(omitted)
        path = joinpath(application, "gui", "operator-views.yaml")
        views = Common.read_yaml(path)
        ids = Set(view["id"] for view in views["view"])
        Set(omitted) ⊆ ids || throw(ArgumentError("mode omits an unknown GUI view"))
        filter!(view -> !(view["id"] in omitted), views["view"])
        Common.write_yaml(path, views)
    end
    return queue_inputs
end
