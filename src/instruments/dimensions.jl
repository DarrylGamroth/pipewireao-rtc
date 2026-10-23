# Declared controller coordinates are authoritative; artifacts are validated later.
function controller_dimensions(authoring, instrument)
    declared = _declaration_object(authoring["dimensions"], "RTC dimensions")
    controller = get(authoring, "controller", nothing)
    derived = Dict{String,Any}()
    if haskey(authoring, "controller")
        _declaration_fields(controller, ("command_count", "hidden_modes"),
            ("command_count", "hidden_modes"), "controller")
        count = controller["command_count"]
        ispositive_integer(count) && count <= typemax(Int) ||
            throw(ArgumentError("controller command_count must be a positive Int"))
        modes = _declaration_array(controller["hidden_modes"], "controller hidden_modes")
        all(InstrumentDefinition.bounded_text, modes) && length(unique(modes)) == length(modes) ||
            throw(ArgumentError("controller hidden_modes must contain distinct nonempty labels"))
        derived["controller_command_count"] = count
        derived["hidden_mode_count"] = length(modes)
        isempty(intersect(Set(keys(declared)), Set(keys(derived)))) ||
            throw(ArgumentError("controller-derived dimensions must not be declared twice"))
    end
    physical = Dict{String,Any}(deepcopy(instrument.document))
    physical["deformable_mirrors"] = Dict(name => merge(Dict{String,Any}(mirror),
        Dict("actuator_count"=>command_count(read_mirror_description(
            mirror_description_path(instrument.directory, mirror["description"])))))
        for (name, mirror) in instrument.document["deformable_mirrors"])
    context = Dict("instrument"=>physical, "rtc"=>Dict("controller"=>controller))
    resolved = Dict{String,Any}(Common.configuration_value(declared, context))
    merge!(resolved, derived)
    _validate_dimensions(resolved)
    return resolved
end
