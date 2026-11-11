const ANALYSIS_START_BUDGET_NS = Int64(20_000_000_000)

function analysis_environment(paths, runtime, role, prefix, remote)
    return Dict(
        "PIPEWIREAO_PREFIX" => prefix,
        "LD_LIBRARY_PATH" => paths["library"],
        "PIPEWIREAO_RUNTIME_DIR" => runtime,
        "PIPEWIRE_RUNTIME_DIR" => runtime,
        "PIPEWIREAO_CONFIG_DIR" => joinpath(runtime, role),
        "PIPEWIREAO_MODULE_DIR" => paths["modules"],
        "PIPEWIREAO_SPA_PLUGIN_DIR" => paths["spa"],
        "PIPEWIREAO_REMOTE" => remote,
        "PIPEWIRE_REMOTE" => remote,
        "CUDA_VISIBLE_DEVICES" => "",
        "ROCR_VISIBLE_DEVICES" => "",
        "HIP_VISIBLE_DEVICES" => "",
        "OPENBLAS_NUM_THREADS" => "1",
        "OMP_NUM_THREADS" => "1",
        "MKL_NUM_THREADS" => "1",
        "JULIA_NUM_THREADS" => "2",
        "JULIA_DEPOT_PATH" =>
            joinpath(runtime, "julia-depot") * ":" *
            get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia") * ":"),
        "JULIA_LOAD_PATH" => "@:@stdlib",
    )
end

function install_analysis!(entry, package, prefix, paths, project, client, record, deadline; clock)
    runtime = record["runtime"]
    coordinator = S.Coordinator(record["unit"], record["invocation"], "")
    role = "analysis-" * entry["name"]
    placement = Dict("cpus" => entry["cpus"], "leader-cpu" => first(entry["cpus"]))
    service = reserve_owner!(coordinator, role, placement, record)
    record["owners"][role]["optional"] = true
    directory = joinpath(runtime, role)
    mkdir(directory; mode = 0o700)
    write(joinpath(directory, "client.conf"), client)
    argv = [
        realpath(Base.julia_cmd().exec[1]),
        "--startup-file=no",
        "--project=" * project,
        "-e",
        "using PipeWireAORTC; exit(PipeWireAORTC.Analysis.main(ARGS))",
        "--",
        "--config",
        D.relative_asset(package, entry["config"]),
        "--remote",
        record["remote"],
    ]
    env = analysis_environment(paths, runtime, role, prefix, basename(record["remote"]))
    # Native Ready has already been proved. The parent is still activating
    # during ExecStartPost, so avoid a dependency on its systemd active state.
    # Julia handles SIGTERM through its runtime exit path, which can stall
    # during compilation. SIGHUP terminates this independent process and its
    # compiler children through the OS. PipeWire releases their objects on disconnect.
    text = S.service_unit(
        service,
        argv,
        env,
        package,
        placement;
        part_of = [coordinator.unit],
        ordinary = true,
        stop_signal = "SIGHUP",
    )
    S.install_fragment!(service.unit, text, runtime, record; deadline, clock)
    return service
end

function analysis_error!(record, error)
    @warn "Optional analysis startup failed; RTC remains admitted" exception = (
        error, catch_backtrace()
    )
    push!(get!(record, "analysis_errors", String[]), sprint(showerror, error))
    try
        launch_record!(record["runtime"], record)
    catch save_error
        @warn "Could not retain optional analysis startup error" exception = (
            save_error, catch_backtrace()
        )
    end
    return nothing
end

# ExecStartPost is the only submitter. systemd terminates the hook before
# ExecStopPost, which can therefore cancel any retained job and remove its unit.
function start_analysis!(package, prefix, spec, record; deadline, clock)
    validate_ledger(record)
    entries = get(spec, "analysis", [])
    isempty(entries) && return nothing
    runtime = record["runtime"]
    try
        current = Clocks.time_nanos(clock)
        current < deadline || fail("no startup budget remains for optional analysis")
        deadline = min(deadline, Base.checked_add(current, ANALYSIS_START_BUDGET_NS))
        paths = D.installed_paths(prefix)
        project = D.application_environment(spec, package)
        client = D.relative_asset(package, spec["client"]["analysis"])
        bindings = Dict(
            "PACKAGE" => package, "PREFIX" => prefix, "RUNTIME" => runtime,
            "REMOTE" => basename(record["remote"]), "INSTANCE" => record["invocation"],
        )
        rendered = D.substitute(read(client, String), bindings; quoted = true)
        services = S.Service[]
        for entry in entries
            try
                push!(services, install_analysis!(
                    entry, package, prefix, paths, project, rendered, record, deadline; clock
                ))
            catch error
                analysis_error!(record, error)
            end
        end
        isempty(services) && return nothing
        result = S.checked(["systemctl", "--user", "daemon-reload"]; deadline, clock)
        result.returncode == 0 || fail("cannot load optional analysis units")
        for service in services
            try
                item = record["owners"][service.role]
                S.verify_fragment!(service.unit, record; ordinary = true, deadline, clock)
                item["state"] = "submitted"
                launch_record!(runtime, record)
                result = S.checked(
                    ["systemctl", "--user", "start", "--no-block", service.unit]; deadline, clock
                )
                result.returncode == 0 || fail("cannot submit optional analysis: $(service.role)")
            catch error
                analysis_error!(record, error)
            end
        end
    catch error
        analysis_error!(record, error)
    end
    return nothing
end
