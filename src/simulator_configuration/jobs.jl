default_root() = get(ENV, "PIPEWIREAO_SIMULATOR_ROOT",
    joinpath(get(ENV, "XDG_STATE_HOME", joinpath(homedir(), ".local", "state")),
        "pipewireao", "simulator-settings"))

function settings_root(root)
    isabspath(root) || throw(ArgumentError("simulator settings root must be absolute"))
    mkpath(root; mode=0o700)
    !islink(root) && stat(root).uid == ccall(:getuid, Cuint, ()) ||
        throw(ArgumentError("simulator settings root must be an owned directory"))
    return realpath(root)
end

function job_directory(root, id)
    id isa AbstractString && occursin(r"^[0-9a-f]{32}$", id) || throw(ArgumentError("invalid rebuild job ID"))
    directory = joinpath(settings_root(root), id)
    isdir(directory) && !islink(directory) || throw(ArgumentError("rebuild job is unavailable"))
    return directory
end

job_unit(id) = "pipewireao-rebuild-$id.service"

function incarnation_directory(request)
    identity = request["identity"]
    invocation = identity["invocation"]
    occursin(r"^[0-9a-f]{32}$", invocation) || throw(ArgumentError("invalid session invocation"))
    root = identity["runtime_root"]
    isabspath(root) || throw(ArgumentError("managed runtime must be absolute"))
    directory = joinpath(root, invocation)
    isdir(directory) && !islink(directory) && stat(directory).uid == ccall(:getuid,Cuint,()) ||
        throw(ArgumentError("managed invocation directory is unavailable"))
    return directory
end

function attempted_replacement(directory)
    request = C.read_json(joinpath(directory,"request.json"); maximum=MAX_REQUEST_BYTES)
    fence = joinpath(incarnation_directory(request),"simulator-rebuild","attempt.json")
    return isfile(fence) && C.read_json(fence;maximum=4096)["job"] == basename(directory)
end

function save_state(directory, state; fields...)
    result = Dict{String,Any}("id"=>basename(directory), "state"=>state)
    merge!(result, Dict(string(key)=>value for (key,value) in fields))
    C.write_json(joinpath(directory, "result.json"), result; atomic=true)
    return result
end

function check_identity(expected, actual)
    expected == actual || throw(ArgumentError("session incarnation or simulator configuration changed; reload settings"))
    return nothing
end

function launch_job(directory)
    project = Base.active_project()
    project !== nothing || throw(ArgumentError("rebuild tool requires an active project"))
    argv = ["systemd-run", "--user", "--quiet", "--no-block", "--unit=$(job_unit(basename(directory)))",
        "--property=Type=oneshot", "--property=RemainAfterExit=yes", "--property=TimeoutStartSec=2400",
        "--property=TimeoutStopSec=30", "--property=KillMode=control-group",
        "--property=UMask=0077", "--property=Nice=5", "--setenv=JULIA_NUM_THREADS=1",
        "--setenv=OPENBLAS_NUM_THREADS=1"]
    for key in ("JULIA_DEPOT_PATH", "XDG_RUNTIME_DIR", "PIPEWIREAO_SIMULATOR_ROOT")
        haskey(ENV, key) && push!(argv, "--setenv=$key=$(ENV[key])")
    end
    append!(argv, [Base.julia_cmd().exec[1], "--startup-file=no", "--project=$(dirname(project))",
        "-e", "using PipeWireAORTC; exit(PipeWireAORTC.SimulatorConfiguration.run_job(ARGS[1]; root=ARGS[2]))",
        "--", basename(directory), dirname(directory)])
    result = C.run_checked(argv; timeout=15, maximum_output_bytes=64 * 1024)
    result.returncode == 0 || throw(ArgumentError("could not start rebuild job: $(result.stderr)"))
    return nothing
end

function reserve_job(root, request)
    return open(joinpath(root, ".reservation.lock"), "a+") do lock
        ccall(:flock, Cint, (Cint, Cint), fd(lock), 2 | 4) == 0 ||
            throw(ArgumentError("another rebuild record is being reserved"))
        try
            count(name -> occursin(r"^[0-9a-f]{32}$", name), readdir(root)) < 256 ||
                throw(ArgumentError("256 rebuild records retained; archive old records before rebuilding"))
            directory = joinpath(root, request["id"])
            mkdir(directory; mode=0o700)
            C.write_json(joinpath(directory, "request.json"), request; atomic=true)
            save_state(directory, "queued")
            return directory
        finally
            ccall(:flock, Cint, (Cint, Cint), fd(lock), 8)
        end
    end
end

"Accept a cold replacement job; disconnecting its client does not cancel it."
function start_rebuild(session_id::AbstractString, configuration_sha256::AbstractString,
        settings::AbstractDict; resume_running::Bool=true, root=default_root(), launch=launch_job)
    occursin(r"^[0-9a-f]{64}$", configuration_sha256) || throw(ArgumentError("invalid configuration SHA-256"))
    selected = selected_session(session_id)
    selected.identity["configuration_sha256"] == configuration_sha256 ||
        throw(ArgumentError("simulator configuration changed; reload settings"))
    # Admission is structural here; pinned scientific validation happens in the
    # durable worker before any request is sent to the old live session.
    AOSOwner.plant_settings(settings)
    root = settings_root(root)
    id = replace(string(uuid4()), "-"=>"")
    request = Dict(
        "id"=>id, "identity"=>selected.identity, "application"=>selected.application,
        "prefix"=>selected.prefix, "relative_config"=>selected.relative,
        "settings"=>settings, "resume_running"=>resume_running)
    ncodeunits(JSON3.write(request)) <= MAX_REQUEST_BYTES ||
        throw(ArgumentError("rebuild record exceeds 64 KiB"))
    directory = reserve_job(root, request)
    try
        launch(directory)
    catch error
        # The systemd job may already be executing. Never overwrite its receipt
        # or lose the ID just because the launcher acknowledgement was lost.
        C.write_json(joinpath(directory, "launch-acknowledgement.json"),
            Dict("acknowledged"=>false,"error"=>sprint(showerror,error)); atomic=true)
        return Dict("id"=>id, "state"=>"queued", "launch_acknowledged"=>false, "error"=>
            "Job launch acknowledgement unavailable; observe the retained job without retrying.")
    end
    return Dict("id"=>id, "state"=>"queued")
end

function job(id::AbstractString; root=default_root(), inspect=SystemdOwners.properties)
    directory = job_directory(root, id)
    result = C.read_json(joinpath(directory, "result.json"); maximum=MAX_REPLY_BYTES)
    result["id"] == id || throw(ArgumentError("rebuild receipt identity differs"))
    result["state"] in TERMINAL && return result
    observed = inspect(job_unit(id); extra="Result")
    if observed["ActiveState"] ∉ ("active", "activating")
        attempted = attempted_replacement(directory) ||
            result["state"] in ("stopping", "starting")
        ambiguous_launch = result["state"] == "queued" &&
            isfile(joinpath(directory, "launch-acknowledgement.json"))
        return merge(result, Dict("state"=>(attempted || ambiguous_launch) ? "unknown" : "failed",
            "error"=>"Rebuild worker ended without a terminal receipt; no operation was retried."))
    end
    return result
end

function prepare_candidate(request, directory; describe_science=scientific_description)
    application, prefix = request["application"], request["prefix"]
    # Validate every original sealed asset before copying or resealing anything.
    original = D.profile(joinpath(application, "deployment.conf"), prefix)
    relative = config_asset(original)
    relative == request["relative_config"] || throw(ArgumentError("simulator configuration asset changed"))
    C.sha256_file(D.relative_asset(application, relative)) == request["identity"]["configuration_sha256"] ||
        throw(ArgumentError("simulator configuration changed before preparation"))
    description = describe_science(application, prefix, relative)
    validate_settings(description["schema"], request["settings"], description["settings"])
    candidate = joinpath(directory, "candidate")
    # A prior installation adds wrappers and instance units. They are not source
    # assets; regenerate them through the ordinary installer for this new path.
    cp(application, candidate; follow_symlinks=true)
    for name in ("systemd", "bin")
        any(startswith(asset, "$name/") for asset in keys(original["artifacts"])) &&
            throw(ArgumentError("rebuild requires an application without sealed installation wrappers"))
        path = joinpath(candidate, name)
        ispath(path) && rm(path; recursive=true)
    end
    document = D.decode(joinpath(candidate, relative), prefix)
    document["plant"]["settings"] = request["settings"]
    C.write_json(joinpath(candidate, relative), document)
    declaration = D.decode(joinpath(candidate, "deployment.conf"), prefix)
    declaration["artifacts"][relative] = C.sha256_file(joinpath(candidate, relative))
    C.write_json(joinpath(candidate, "deployment.conf"), declaration)
    D.profile(joinpath(candidate, "deployment.conf"), prefix)
    describe_science(candidate, prefix, relative; prepare=true, log_directory=directory)
    return candidate
end

function rebuild(request, directory; select=selected_session, prepare=prepare_candidate,
        shutdown=R.shutdown!, start=R.start!, control=R.control!, ledger=R._ledger)
    save_state(directory, "preparing")
    candidate = prepare(request, directory)
    selected = select(request["identity"]["session_id"])
    check_identity(request["identity"], selected.identity)
    handle = selected.handle
    # Retain the actual installation stage: shutdown! uses it for both its
    # durable attempt receipt and exact owned-unit unlinking after cleanup.
    handle.stage_root !== nothing || throw(ArgumentError("session installation receipt is unavailable"))
    fence = joinpath(incarnation_directory(request),"simulator-rebuild","attempt.json")
    isfile(fence) && throw(ArgumentError("replacement was already attempted for this session incarnation"))
    C.write_json(fence, Dict("job"=>basename(directory), "identity"=>selected.identity); atomic=true)
    save_state(directory, "stopping"; previous_application=selected.application)
    shutdown(handle; deadline=R.monotonic()+320)
    save_state(directory, "starting"; previous_application=selected.application)
    stage = joinpath(directory, "replacement")
    replacement = start(candidate, stage; prefix=selected.prefix, deadline=R.monotonic()+1050)
    status = control(replacement, NativeSessionCodec.RunnerCommand(:status); deadline=R.monotonic()+15)
    status["ok"] === true && status["state"] == "Ready" ||
        throw(ArgumentError("replacement native admission did not confirm Ready"))
    if request["resume_running"]
        running = control(replacement, NativeSessionCodec.RunnerCommand(:session_start); deadline=R.monotonic()+30)
        running["ok"] === true && running["state"] == "Running" ||
            throw(ArgumentError("replacement native Start did not confirm Running"))
    end
    admitted = ledger(replacement)
    return save_state(directory, "complete"; locator=admitted["discovery_locator"],
        session_id=admitted["session_uuid"], stage,
        previous_application=selected.application,
        configuration_sha256=C.sha256_file(joinpath(stage, "installed", request["relative_config"])))
end

function run_job(id::AbstractString; root=default_root(), execute=rebuild)
    directory = job_directory(root, id)
    request = C.read_json(joinpath(directory, "request.json"); maximum=MAX_REQUEST_BYTES)
    request["id"] == id || throw(ArgumentError("rebuild request identity differs"))
    # Independent GUI/CLI management roots must share the same incarnation lock.
    lock_directory = joinpath(incarnation_directory(request), "simulator-rebuild")
    mkpath(lock_directory; mode=0o700)
    return open(joinpath(lock_directory, "replacement.lock"), "a+") do lock
        acquired = ccall(:flock, Cint, (Cint, Cint), fd(lock), 2 | 4) == 0
        if !acquired
            save_state(directory, "failed"; error="Another rebuild is already preparing this session.")
            return 1
        end
        try
            current = C.read_json(joinpath(directory, "result.json"))
            current["state"] == "queued" || return current["state"] == "complete" ? 0 : 1
            execute(request, directory)
            return 0
        catch error
            current = C.read_json(joinpath(directory, "result.json"))
            attempted = current["state"] in ("stopping", "starting") || attempted_replacement(directory)
            failure = joinpath(directory, "replacement", "start-failure.json")
            confirmed = isfile(failure) ? get(C.read_json(failure), "cleanup_confirmed", false) : false
            save_state(directory, attempted && !confirmed ? "unknown" : "failed";
                error=sprint(showerror,error), previous_application=request["application"],
                stage=joinpath(directory,"replacement"), cleanup_confirmed=confirmed)
            return 1
        finally
            ccall(:flock, Cint, (Cint, Cint), fd(lock), 8)
        end
    end
end
