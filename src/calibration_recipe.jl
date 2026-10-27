"""
    read_recipe(application)

Read the canonical `calibration/recipe.yaml` compiled as `recipe.conf` in a
built application. Reject unknown fields and unsupported sensor procedures.
No optical execution or accelerator loading is required.
"""
function read_recipe(application)
    require_prepared_application(application)
    path = DeploymentConfiguration.relative_asset(application, "calibration/recipe.conf")
    recipe = DeploymentConfiguration.decode(path, get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    common = ("version", "simulation", "rtc_configuration", "graph", "graph_source", "sensor", "poke_m", "tsvd_rtol")
    all(key -> haskey(recipe,key),common) || throw(ArgumentError("incomplete calibration recipe"))
    recipe["version"] isa Integer && !(recipe["version"] isa Bool) && recipe["version"] == 1 ||
        throw(ArgumentError("unsupported calibration recipe version"))
    for key in ("simulation", "rtc_configuration", "graph", "graph_source")
        DeploymentConfiguration.relative_asset(application, recipe[key])
    end
    DeploymentConfiguration.relative_asset(application,recipe["graph_source"]) !=
        DeploymentConfiguration.relative_asset(application,recipe["graph"]) ||
        throw(ArgumentError("calibration graph template and execution graph must be distinct files"))
    declaration = InstrumentConfiguration.load_simulation(joinpath(application,recipe["simulation"]))
    sensor = get(declaration.instrument.document["wavefront_sensors"],recipe["sensor"],nothing)
    sensor === nothing && throw(ArgumentError("calibration sensor is not declared"))
    kind = InstrumentConfiguration.sensor_kind(sensor)
    extra = kind isa Val{:shack_hartmann} ?
        ("settings", "mirror", "source_completion", "estimator") :
        ("settings", "mirrors", "tiptilt", "temporal")
    Set(keys(recipe)) ⊆ Set((common...,extra...)) || throw(ArgumentError("unknown calibration recipe fields"))
    for key in ("poke_m", "tsvd_rtol")
        value=recipe[key]
        InstrumentConfiguration.isfinite_real(value) && value>0 && isfinite(Float32(value)) && Float32(value)>0 ||
            throw(ArgumentError("calibration $key must be positive and finite in Float32"))
    end
    recipe["tsvd_rtol"] < 1 || throw(ArgumentError("calibration tsvd_rtol must be below one"))
    required = kind isa Val{:shack_hartmann} ? ("mirror","source_completion","estimator") : ("mirrors","tiptilt")
    all(key->haskey(recipe,key),required) || throw(ArgumentError("incomplete sensor calibration recipe"))
    InstrumentConfiguration.settings(declaration,get(recipe,"settings",Dict()))
    if kind isa Val{:shack_hartmann}
        InstrumentConfiguration.fields(recipe["source_completion"],("path","sha256","shape","axes"),
            ("path","sha256","shape","axes"),"source completion")
        DeploymentConfiguration.relative_asset(application,recipe["source_completion"]["path"])
        estimator_fields=("feedback_input","detector_shape","slopes_output","validity_output",
            "measurement_count","raw_input","flux_output")
        InstrumentConfiguration.fields(recipe["estimator"],estimator_fields,estimator_fields,"calibration estimator")
        haskey(declaration.instrument.document["deformable_mirrors"],recipe["mirror"]) ||
            throw(ArgumentError("calibration mirror is not declared"))
    else
        entries=recipe["mirrors"]
        entries isa AbstractVector && !isempty(entries) || throw(ArgumentError("calibration mirrors must be a nonempty list"))
        names=String[]
        for entry in entries
            InstrumentConfiguration.fields(entry,("name","mode_count","completion"),("name",),"calibration mirror")
            haskey(entry,"mode_count") ⊻ haskey(entry,"completion") ||
                throw(ArgumentError("calibration mirror requires exactly one mode_count or completion"))
            haskey(entry,"mode_count") && !InstrumentConfiguration.ispositive_integer(entry["mode_count"]) &&
                throw(ArgumentError("calibration mode_count must be a positive integer"))
            haskey(declaration.instrument.document["deformable_mirrors"],entry["name"]) ||
                throw(ArgumentError("calibration mirror is not declared"))
            push!(names,entry["name"])
        end
        length(unique(names))==length(names) || throw(ArgumentError("calibration mirrors must be distinct"))
        stage_fields=("command_input","mirror","command_limits_m")
        InstrumentConfiguration.fields(recipe["tiptilt"],stage_fields,stage_fields,"calibration tiptilt")
        recipe["tiptilt"]["mirror"] in names || throw(ArgumentError("tiptilt mirror must be calibrated"))
        limits=recipe["tiptilt"]["command_limits_m"]
        limits isa AbstractVector && length(limits)==2 || throw(ArgumentError("tiptilt requires lower/upper limits"))
        checked_command_limits(Float32,limits...,2)
        _tiptilt_temporal(recipe,declaration.document["frame_period_s"])
    end
    rtc=InstrumentConfiguration.load_rtc(joinpath(application,recipe["rtc_configuration"]))
    context=InstrumentExport.graph_context(InstrumentConfiguration.json_value(
        InstrumentConfiguration.physical_definition(rtc.instrument));
        dimensions=rtc.document["dimensions"],mirror_controls=rtc.controls["deformable_mirrors"],
        calibration=rtc.calibration)
    prefix=get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao")
    InstrumentExport.resolve_graph_configuration(DeploymentConfiguration.decode(
        joinpath(application,recipe["graph_source"]),prefix),context)==
        DeploymentConfiguration.decode(joinpath(application,recipe["graph"]),prefix) ||
        throw(ArgumentError("compiled calibration graph differs from its retained template; rebuild the application"))
    context["graphs"]=InstrumentExport.graph_contract_context(application,
        [Dict("path"=>recipe["graph"])],get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))
    authored=InstrumentConfiguration.bounded_yaml(joinpath(application,"calibration/recipe.yaml"))
    Common.configuration_value(authored,context)==recipe ||
        throw(ArgumentError("compiled calibration recipe differs from authoring; rebuild the application"))
    return recipe
end

"Run a declared sensor procedure and produce the standard calibration bundle."
function calibrate_system(application, output; kwargs...)
    output=_calibration_output((application,),output)
    recipe=read_recipe(application)
    declaration=InstrumentConfiguration.load_simulation(joinpath(application,recipe["simulation"]))
    kind=InstrumentConfiguration.sensor_kind(declaration.instrument.document["wavefront_sensors"][recipe["sensor"]])
    return _calibrate_system(kind, application, recipe, output; kwargs...)
end
function _calibrate_system end

"Validate a standard calibration bundle against its declared instrument model."
function validate_system(application, calibration, output; kwargs...)
    output=_calibration_output((application,calibration),output)
    recipe=read_recipe(application)
    declaration=InstrumentConfiguration.load_simulation(joinpath(application,recipe["simulation"]))
    kind=InstrumentConfiguration.sensor_kind(declaration.instrument.document["wavefront_sensors"][recipe["sensor"]])
    bundle=read_bundle(calibration)
    # Recipes in the receipt describe the acquisition; current authoring cannot
    # silently change settings, normalization or controller policy during replay.
    recipe==bundle.report["recipe"] || throw(ArgumentError("calibration recipe differs from the selected application"))
    return _validate_system(kind, application, recipe, calibration, output; kwargs...)
end
function _validate_system end
"Stage a bundle verified against its built application into a fresh authored source copy."
function stage_calibration end

function _calibration_output(inputs, output)
    destination=InstrumentExport.checked_path(output)
    !ispath(destination) && !islink(destination) || throw(ArgumentError("calibration output must be fresh"))
    all(input->InstrumentExport.outside(relpath(destination,InstrumentExport.checked_path(input))),inputs) ||
        throw(ArgumentError("calibration output must be outside its inputs"))
    return destination
end
