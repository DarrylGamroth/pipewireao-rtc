# Required pre-admission session manager; scientific control stays in Deployment.
# Included in Deployment so it reuses the existing owned-process/deadline paths.
function validate_session_manager(value)
    require(value isa AbstractDict && Set(keys(value)) == Set(["argv", "environment", "marker-node"]),
        "session-manager requires argv, environment and marker-node")
    argv = value["argv"]
    require(argv isa AbstractVector && 1 <= length(argv) <= 256 &&
        all(arg -> arg isa String && !occursin('\0', arg), argv) && !isempty(first(argv)),
        "session-manager argv must be a bounded nonempty string list")
    validate_environment(value["environment"], "session-manager")
    require(value["marker-node"] isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$", value["marker-node"]),
        "session-manager requires an exact bounded realization marker name")
    for (flag, argument) in (("-c", "@RUNTIME@/wireplumber/wireplumber.conf"), ("-p", "ao-rtc"))
        indices = findall(==(flag), argv)
        require(length(indices) == 1 && only(indices) < length(argv) && argv[only(indices)+1] == argument,
            "session-manager requires the exact $flag binding")
    end
    return nothing
end

function session_manager_configuration(marker, remote)
    quoted(value) = String(JSON3.write(value))
    return """
    context.properties = { library.use-fallback = false support.dbus = false remote.name = $(quoted(remote)) }
    context.modules = [ { name = libpipewire-module-protocol-native } ]
    wireplumber.profiles = {
        ao-rtc = { support.lua-scripting = required ao.rtc-realization = required }
    }
    wireplumber.components = [
        { name = libwireplumber-module-lua-scripting type = module provides = support.lua-scripting }
        { name = realization.lua type = script/lua provides = ao.rtc-realization
          requires = [ support.lua-scripting ] arguments = { node.name = $(quoted(marker)) } }
    ]
    """
end

function start_session_manager!(deployment, bindings)
    manager = get(deployment.spec, "session-manager", nothing)
    manager === nothing && return String[]
    runtime = something(deployment.runtime)
    remote = joinpath(runtime, bindings["REMOTE"])
    write(joinpath(runtime, "wireplumber/wireplumber.conf"),
        session_manager_configuration(manager["marker-node"], remote))
    env = environment(deployment, "wireplumber", bindings)
    merge!(env, Dict(key => substitute(value, bindings) for (key, value) in manager["environment"]))
    merge!(env, Dict("PIPEWIRE_REMOTE"=>remote, "PIPEWIREAO_REMOTE"=>remote, "NOTIFY_SOCKET"=>""))
    deployment.source_owner === nothing || (deployment.record["source_before_link_realization"] = deepcopy(deployment.record["source"]))
    process = spawn(deployment, "wireplumber", [substitute(arg, bindings) for arg in manager["argv"]], env)
    deadline = monotonic() + 10
    observed = nothing
    while observed === nothing
        check(deployment)
        remaining = deadline - monotonic()
        remaining > 0 || fail("session-manager exact client discovery timed out")
        snapshot = Common.run_checked([joinpath(deployment.options.pipewire_prefix,"bin/pwao-dump"),"-r",remote];
            env=Dict("LD_LIBRARY_PATH"=>deployment.paths["library"]), timeout=min(remaining,2),
            maximum_output_bytes=4*1024*1024)
        require(snapshot.returncode == 0, "session-manager registry inspection failed")
        matches = filter(Common.parse_json(snapshot.stdout)) do object
            object["type"] == "PipeWire:Interface:Client" &&
                string(get(object["info"]["props"], "application.process.id", "")) == string(getpid(process))
        end
        require(length(matches) <= 1, "session-manager published multiple creator clients")
        isempty(matches) || (observed = only(matches))
        observed === nothing && sleep(min(0.01,max(0,deadline-monotonic())))
    end
    id = observed["id"]
    serial = get(observed["info"]["props"],"object.serial",nothing)
    require(id isa Integer && !(id isa Bool) && 0 < id < typemax(UInt32) &&
        serial !== nothing && tryparse(UInt64,string(serial)) !== nothing && parse(UInt64,string(serial)) > 0,
        "session-manager has an invalid exact client identity")
    deployment.record["session_manager"] = Dict("id"=>id,"serial"=>serial,"pid"=>getpid(process),
        "marker"=>manager["marker-node"])
    return ["--wireplumber-client", string(id), string(serial), "--realization-node", manager["marker-node"]]
end
