json_value(value) = C.parse_json(String(JSON3.write(value)))

function merge_settings(defaults::AbstractDict, overrides::AbstractDict)
    result = deepcopy(defaults)
    for (key, value) in overrides
        haskey(defaults, key) || throw(ArgumentError("unknown simulator setting $key"))
        result[key] = value isa AbstractDict && defaults[key] isa AbstractDict ?
            merge_settings(defaults[key], value) : deepcopy(value)
    end
    return result
end

"Enforce the declared editable shape; physical validation remains with the plant."
function validate_settings(schema, proposed, current; path="settings", readonly=false)
    schema isa AbstractDict || throw(ArgumentError("invalid settings schema"))
    readonly |= get(schema, "readOnly", false) === true
    readonly && proposed != current && throw(ArgumentError("$path requires a separate calibration/deployment change"))
    kind = get(schema, "type", nothing)
    if kind == "object"
        proposed isa AbstractDict && current isa AbstractDict || throw(ArgumentError("$path must be an object"))
        properties = get(schema, "properties", Dict())
        Set(keys(proposed)) == Set(keys(current)) == Set(keys(properties)) ||
            throw(ArgumentError("$path must contain exactly the declared settings"))
        for key in keys(properties)
            validate_settings(properties[key], proposed[key], current[key]; path="$path.$key", readonly)
        end
    elseif kind == "array"
        proposed isa AbstractVector && current isa AbstractVector || throw(ArgumentError("$path must be an array"))
        length(proposed) <= 256 || throw(ArgumentError("$path exceeds 256 values"))
        length(proposed) >= get(schema, "minItems", 0) || throw(ArgumentError("$path has too few values"))
        length(proposed) <= get(schema, "maxItems", 256) || throw(ArgumentError("$path has too many values"))
        get(schema, "uniqueItems", false) && length(unique(proposed)) != length(proposed) &&
            throw(ArgumentError("$path requires unique values"))
        for (index, value) in enumerate(proposed)
            base = index <= length(current) ? current[index] : value
            validate_settings(schema["items"], value, base; path="$path[$index]", readonly)
        end
    elseif kind in ("number", "integer")
        proposed isa Real && !(proposed isa Bool) && isfinite(proposed) ||
            throw(ArgumentError("$path must be a finite number"))
        kind == "integer" && !(proposed isa Integer) && throw(ArgumentError("$path must be an integer"))
        for (key, compare) in (("minimum", >=), ("maximum", <=), ("exclusiveMinimum", >), ("exclusiveMaximum", <))
            haskey(schema, key) && !compare(proposed, schema[key]) && throw(ArgumentError("$path violates $key"))
        end
    elseif kind == "string"
        proposed isa AbstractString && !occursin('\0', proposed) && ncodeunits(proposed) <= 16 * 1024 ||
            throw(ArgumentError("$path must be a bounded string"))
    elseif kind == "boolean"
        proposed isa Bool || throw(ArgumentError("$path must be Boolean"))
    else
        throw(ArgumentError("unsupported settings schema type $kind"))
    end
    haskey(schema, "enum") && proposed ∉ schema["enum"] && throw(ArgumentError("$path is not an admitted value"))
    return nothing
end

function declared_settings(instrument::Module, overrides)
    isdefined(instrument, :describe_hil_settings) ||
        throw(ArgumentError("$(nameof(instrument)) does not declare editable simulator settings; update the application"))
    declaration = json_value(Base.invokelatest(getproperty(instrument, :describe_hil_settings)))
    defaults, schema = declaration["defaults"], declaration["schema"]
    settings = merge_settings(defaults, overrides)
    validate_settings(schema, settings, settings)
    return Dict("package" => string(nameof(instrument)), "settings" => settings, "schema" => schema)
end

"Worker executed in the application's pinned Julia environment, without ports."
function scientific_worker(config, output; prepare=false)
    options = AOSOwner.configuration(config)
    options.plant !== nothing || throw(ArgumentError("editable settings require a declared instrument plant"))
    instrument = AOSOwner.load_instrument(options.plant.package)
    result = declared_settings(instrument, json_value(options.plant.settings))
    if prepare
        Base.require(Main, :AdaptiveOpticsSim)
        Base.require(Main, :AdaptiveOpticsSimPipeWireHIL)
        options.backend === :cuda && Base.require(Main, :CUDA)
        invocation = merge(options, (; plant_module=instrument,
            remote=joinpath(dirname(output), "unused-preflight-socket"), control_node="simulator-preflight"))
        Base.invokelatest(AOSOwner.prepare_science, invocation)
        result["prepared"] = true
    end
    C.write_json(output, result; atomic=true)
    return nothing
end

function scientific_description(application, prefix, relative_config; prepare=false, log_directory=nothing)
    spec = D.profile(joinpath(application, "deployment.conf"), prefix)
    environment = D.application_environment(spec, application)
    return mktempdir() do directory
        output = joinpath(directory, "description.json")
        argv = [Base.julia_cmd().exec[1], "--startup-file=no", "--project=$environment", "-e",
            "using PipeWireAORTC; PipeWireAORTC.SimulatorConfiguration.worker_main(ARGS)", "--",
            prepare ? "preflight" : "describe", D.relative_asset(application, relative_config), output]
        result = C.run_checked(argv; timeout=prepare ? 900 : 50,
            stdout_path=log_directory === nothing ? nothing : joinpath(log_directory, "preflight.stdout"),
            stderr_path=log_directory === nothing ? nothing : joinpath(log_directory, "preflight.stderr"),
            maximum_output_bytes=1024 * 1024)
        result.returncode == 0 || throw(ArgumentError("simulator $(prepare ? "preparation" : "description") failed: $(last(result.stderr, 4096))"))
        return C.read_json(output; maximum=MAX_REPLY_BYTES)
    end
end

function config_asset(spec)
    role = spec["source-owner"]
    owners = filter(owner -> owner["role"] == role, spec["owners"])
    length(owners) == 1 || throw(ArgumentError("session has no unique declared simulator owner"))
    argv = only(owners)["argv"]
    indices = findall(==("--config"), argv)
    length(indices) == 1 && only(indices) < length(argv) || throw(ArgumentError("source has no unique configuration"))
    value = argv[only(indices) + 1]
    startswith(value, "@PACKAGE@/") || throw(ArgumentError("simulator configuration must be an application asset"))
    relative = chopprefix(value, "@PACKAGE@/")
    haskey(spec["artifacts"], relative) || throw(ArgumentError("simulator configuration must be sealed"))
    return String(relative)
end

function selected_session(session_id)
    connection = SessionCLI.select_direct_session(session_id)
    try
        selected = connection.selected
        status = selected.status
        status.lifecycle in (:ready, :running) || throw(ArgumentError("simulator replacement requires Ready or Running"))
        runtime = dirname(status.remote)
        handle = R.attach(dirname(runtime))
        ledger = R._ledger(handle)
        ledger["runtime"] == runtime && ledger["session_uuid"] == session_id &&
            handle.main_pid == status.owner_pid && ledger["session_control_instance"] == status.incarnation ||
            throw(ArgumentError("native session and managed invocation differ"))
        R._verify_owners(handle, ledger, R.monotonic()+15)
        properties = SystemdOwners.properties(handle.unit; extra="FragmentPath")
        application = dirname(dirname(realpath(properties["FragmentPath"])))
        basename(application) == "installed" && isfile(joinpath(dirname(application), "session.json")) ||
            throw(ArgumentError("managed simulator has no retained installation receipt"))
        installed = R.attach(dirname(application))
        (installed.unit, installed.invocation, installed.main_pid, installed.start_ticks) ==
            (handle.unit, handle.invocation, handle.main_pid, handle.start_ticks) ||
            throw(ArgumentError("installation receipt and selected session differ"))
        handle = installed
        executable = realpath("/proc/$(handle.main_pid)/exe")
        prefix = dirname(dirname(executable))
        realpath(joinpath(prefix, "bin", "pipewireao-rtc")) == executable ||
            throw(ArgumentError("managed RTC prefix is unavailable"))
        spec = D.profile(joinpath(application, "deployment.conf"), prefix)
        relative = config_asset(spec)
        config = D.relative_asset(application, relative)
        source = ledger["owners"][spec["source-owner"]]
        control_node = only(filter(owner -> owner["role"] == spec["source-owner"], spec["owners"]))["control-node"]
        report = C.read_json(joinpath(runtime, control_node * "-report.json"); maximum=64 * 1024)
        # Only immutable startup identity is read from this report. Run state
        # and live readiness continue to come from the verified native endpoint.
        report["owner_pid"] == source["pid"] &&
            string(report["bootstrap_instance"]) == string(source["bootstrap-instance"]) &&
            realpath(report["configuration"]) == config &&
            report["configuration_sha256"] == C.sha256_file(config) ||
            throw(ArgumentError("saved simulator configuration differs from the running source"))
        return (; handle, application, prefix, relative, spec,
            identity=Dict("session_id"=>String(session_id), "invocation"=>handle.invocation,
                "owner_pid"=>handle.main_pid, "start_ticks"=>handle.start_ticks,
                "incarnation"=>status.incarnation, "runtime_root"=>handle.runtime_root,
                "configuration_sha256"=>C.sha256_file(config)))
    finally
        close(connection)
    end
end

function describe(session_id::AbstractString)
    selected = selected_session(session_id)
    result = scientific_description(selected.application, selected.prefix, selected.relative)
    result["session_id"] = String(session_id)
    result["configuration_sha256"] = selected.identity["configuration_sha256"]
    return result
end
