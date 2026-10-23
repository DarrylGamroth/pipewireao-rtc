# Cold composition of ordinary application/session/core configuration fragments.
# There is no instrument identity or device plugin selection in this code.
function merge_configuration(base::AbstractDict, fragment::AbstractDict)
    result = deepcopy(base)
    for (key, value) in fragment
        result[key] = haskey(result, key) ? merge_configuration(result[key], value) : deepcopy(value)
    end
    return result
end
merge_configuration(base::AbstractVector, fragment::AbstractVector) = vcat(base, fragment)
merge_configuration(base, fragment) = deepcopy(fragment)

function selected_mode(source, profile)
    path = joinpath(source, "rtc", "modes.conf")
    if !isfile(path)
        isempty(intersect(Set(keys(profile)), Set(["mode", "devices", "calibration"]))) ||
            throw(ArgumentError("instrument has no declared application modes"))
        return Dict("application" => Dict())
    end
    document = Common.read_json(path)
    Set(keys(document)) == Set(["default", "modes"]) || throw(ArgumentError("invalid application modes fields"))
    name = get(profile, "mode", document["default"])
    name isa AbstractString && haskey(document["modes"], name) ||
        throw(ArgumentError("unknown instrument application mode"))
    mode = document["modes"][name]
    mode isa AbstractDict && Set(keys(mode)) ⊆ Set(["application", "session", "core", "omit-views", "requires"]) &&
        haskey(mode, "application") || throw(ArgumentError("invalid application mode fields"))
    for field in get(mode, "requires", [])
        field in ("devices", "calibration") || throw(ArgumentError("unknown application mode requirement"))
        haskey(profile, field) || throw(ArgumentError("selected mode requires explicit $field configuration"))
        profile[field] === nothing && throw(ArgumentError("selected mode requires non-null $field configuration"))
    end
    devices = get(profile, "devices", [])
    devices isa AbstractVector && all(device -> device isa AbstractDict, devices) ||
        throw(ArgumentError("devices must be ordinary native owner declarations"))
    "devices" in get(mode, "requires", []) && isempty(devices) &&
        throw(ArgumentError("selected mode requires device owners"))
    return mode
end

function prepare_mode!(application, spec, mode, profile, bindings, prefix)
    for (field, path) in (("session", spec["session"]), ("core", spec["core"]))
        fullpath = D.relative_asset(application, path)
        original = D.decode(fullpath, prefix)
        combined = merge_configuration(original, get(mode, field, Dict()))
        ScienceExport.write_spa_config(fullpath, substitute(combined, bindings))
    end
    calibration = get(profile, "calibration", nothing)
    if calibration !== nothing
        calibration isa AbstractDict && Set(keys(calibration)) == Set(["parameters", "identity"]) ||
            throw(ArgumentError("calibration requires parameters and identity"))
        identity = calibration["identity"]
        identity isa AbstractString && !isempty(identity) || throw(ArgumentError("calibration identity must be nonempty"))
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
        simulation = D.decode(joinpath(application, "simulation.conf"), prefix)
        simulation["calibration_identity"] = identity
        Common.write_json(joinpath(application, "simulation.conf"), simulation)
    end
    omitted = get(mode, "omit-views", [])
    if !isempty(omitted)
        path = joinpath(application, "gui", "operator-views.yaml")
        views = Common.read_yaml(path)
        ids = Set(view["id"] for view in views["view"])
        Set(omitted) ⊆ ids || throw(ArgumentError("mode omits an unknown GUI view"))
        filter!(view -> !(view["id"] in omitted), views["view"])
        YAML.write_file(path, views)
    end
    return nothing
end
