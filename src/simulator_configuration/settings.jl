import ..InstrumentConfiguration: json_value, merge_settings, validate_settings

function declared_settings(instrument::Module, overrides)
    isdefined(instrument, :describe_hil_settings) ||
        throw(ArgumentError("$(nameof(instrument)) does not declare editable simulator settings; update the application"))
    describe = getproperty(instrument, :describe_hil_settings)
    selected = AOSOwner.plant_settings(overrides)
    declaration = json_value(Base.invokelatest(applicable, describe, selected) ?
        Base.invokelatest(describe, selected) : Base.invokelatest(describe))
    defaults, schema = declaration["defaults"], declaration["schema"]
    settings = merge_settings(defaults, overrides, schema)
    validate_settings(schema, settings, settings)
    return Dict("package" => string(nameof(instrument)), "settings" => settings, "schema" => schema)
end

"Worker executed in the application's pinned Julia environment, without ports."
function scientific_worker(config, output; prepare=false)
    options = AOSOwner.configuration(config)
    options.plant !== nothing || throw(ArgumentError("editable settings require a declared instrument plant"))
    instrument = options.version == 3 ? nothing : AOSOwner.load_instrument(options.plant.package)
    # Return configured relative filenames; scientific preparation uses the
    # independently resolved application-local file inputs in options.
    configured = D.decode(config,get(ENV,"PIPEWIREAO_PREFIX","/opt/pipewireao"))["plant"]["settings"]
    result = options.version == 3 ?
        InstrumentConfiguration.settings_description(InstrumentConfiguration.load_simulation(options.plant.definition),configured) :
        declared_settings(instrument, configured)
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
