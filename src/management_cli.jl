"""Owner-side management dispatch and user-service installation.

The native companion owns IPC, admission, descriptors, receipts and worker
lifetime. Existing owner modules retain their artifact/scientific semantics.
"""
module ManagementCLI

using JSON
import ..ConfigurationStore
import ..ConfigurationStoreCLI
import ..SimulatorConfiguration
import ..Artifacts

public respond, serve, install

const PROTOCOL = "pipewireao.management/1"

function registration(request)
    arguments = request["arguments"]
    path = get(arguments, "path", nothing)
    parent = ccall(:getppid, Cint, ())
    return registration(request, arguments, path, parent)
end
registration(request, arguments, path, parent) =
    throw(ArgumentError("registration requires an owner-retained input descriptor"))
function registration(request, arguments, path::AbstractString, parent)
    occursin(Regex("^/proc/$parent/fd/[0-9]+\$"), path) ||
        throw(ArgumentError("registration requires an owner-retained input descriptor"))
    # This is the one intentional proc-fd boundary. Artifacts.snapshot continues
    # rejecting symlinks and reads only our private regular-file copy below.
    return open(path, "r") do input
        before = stat(input)
        isfile(before) && 0 <= before.size <= Artifacts.MAX_FITS_BYTES ||
            throw(ArgumentError("registration input must be a bounded regular file"))
        mktemp() do temporary, output
            buffer = Vector{UInt8}(undef, min(1024 * 1024, before.size))
            remaining = before.size
            while remaining > 0
                count = min(length(buffer), remaining)
                read!(input, view(buffer, 1:count))
                write(output, view(buffer, 1:count))
                remaining -= count
            end
            flush(output)
            after = stat(input)
            (before.size, before.mtime, before.ctime) ==
            (after.size, after.mtime, after.ctime) ||
                throw(ArgumentError("registration input changed during transfer"))
            owned = copy(request)
            owned["arguments"] = merge(arguments, Dict("path" => temporary))
            ConfigurationStoreCLI.request_result(owned)
        end
    end
end

"Dispatch only the existing management domains; live native controls stay separate."
function respond(line::AbstractString)
    try
        # The companion enforces 64 KiB on the wire; trusted root/descriptor
        # substitution can add bounded path bytes before this worker sees it.
        ncodeunits(line) <= 80 * 1024 ||
            throw(ArgumentError("expanded management request exceeds byte limit"))
        request = JSON.parse(line, Dict{String,Any})
        return request_response(request, line)
    catch error
        return Dict("ok" => false, "error" => sprint(showerror, error))
    end
end

request_response(request, line) =
    throw(ArgumentError("management request must be an object"))
function request_response(request::AbstractDict, line)
    protocol = get(request, "protocol", nothing)
    if protocol == ConfigurationStore.PROTOCOL
        # The companion supplies the selected root and, for registration,
        # substitutes its retained input descriptor. CLI tools retain their
        # own unchanged direct-file interface in ConfigurationStoreCLI.
        result =
            get(request, "op", nothing) == "register" ? registration(request) :
            ConfigurationStoreCLI.request_result(request)
        response = Dict("ok" => true, "result" => result)
        ncodeunits(JSON.json(response)) <= ConfigurationStoreCLI.MAX_REPLY_BYTES ||
            throw(ArgumentError("configuration reply exceeds byte limit"))
        return response
    elseif protocol == SimulatorConfiguration.PROTOCOL
        if get(request, "op", nothing) == "start_rebuild"
            id = pop!(request, "id", nothing)
            id = rebuild_request_id(id)
            result = Base.invokelatest(
                SimulatorConfiguration.request_result, request; request_id = id
            )
            response = Dict("ok" => true, "result" => result)
            ncodeunits(JSON.json(response)) <= SimulatorConfiguration.MAX_REPLY_BYTES ||
                throw(ArgumentError("simulator reply exceeds byte limit"))
            return response
        end
        return Base.invokelatest(SimulatorConfiguration.respond, line)
    end
    throw(ArgumentError("unsupported management request domain"))
end

rebuild_request_id(value) =
    throw(ArgumentError("rebuild requires its owner management request identity"))
function rebuild_request_id(value::AbstractString)
    occursin(r"^[0-9a-f]{32}$", value) || return rebuild_request_id(nothing)
    return value
end

"Serve the companion's bounded stdio worker; this is not a socket listener."
serve(input::IO = stdin, output::IO = stdout) =
    ConfigurationStoreCLI.serve(input, output; responder = respond)

absolute_path(value, field) =
    throw(ArgumentError("$field must be an absolute path without control characters"))
function absolute_path(value::AbstractString, field)
    isabspath(value) && isvalid(value) && !any(iscntrl, value) ||
        throw(ArgumentError("$field must be an absolute path without control characters"))
    return String(value)
end

function state_root()
    home = get(ENV, "XDG_STATE_HOME", "")
    isabspath(home) || (home = joinpath(homedir(), ".local", "state"))
    return joinpath(home, "pipewireao", "management")
end

function active_project()
    project = Base.active_project()
    project === nothing &&
        throw(ArgumentError("management installation requires a tooling project"))
    return dirname(project)
end

# Follow the existing session unit writer's JSON/C-style quoting and escape
# systemd specifiers. ExecStart additionally expands $, Environment does not.
unit_value(value) = String(JSON.json(replace(String(value), "%" => "%%")))
unit_argument(value) = unit_value(replace(String(value), "\$" => "\$\$"))

function unit_texts(
    prefix;
    project = active_project(),
    configuration_root = ConfigurationStore.default_root(),
    root = state_root(),
    simulator_root = SimulatorConfiguration.default_root(),
)
    prefix = absolute_path(prefix, "prefix")
    project = absolute_path(project, "project")
    configuration_root = absolute_path(configuration_root, "configuration root")
    root = absolute_path(root, "management state root")
    simulator_root = absolute_path(simulator_root, "simulator root")
    # Management is cold, bounded tooling. Collect temporary compiler/validation
    # allocations promptly without changing compilation of artifact packing or jobs.
    argv = [
        Base.julia_cmd().exec[1],
        "--startup-file=no",
        "--heap-size-hint=256M",
        "--project=$project",
        "-e",
        "using PipeWireAORTC; PipeWireAORTC.ManagementCLI.serve()",
    ]
    # systemd resolves the executable word without argv environment expansion.
    executable = unit_value(joinpath(prefix, "bin", "pipewireao-management"))
    arguments = unit_argument.([
        "--worker-argv",
        String(JSON.json(argv)),
        "--configuration-root",
        configuration_root,
        "--state-root",
        root,
    ])
    command = executable * " " * join(arguments, " ")
    environment = [
        "PIPEWIREAO_PREFIX" => prefix,
        "LD_LIBRARY_PATH" => joinpath(prefix, "lib"),
        "PIPEWIREAO_SPA_PLUGIN_DIR" => joinpath(prefix, "lib", "spa-ao-0.2"),
        "PIPEWIREAO_MODULE_DIR" => joinpath(prefix, "lib", "pipewire-ao-0.3"),
        "PIPEWIREAO_CONFIG_DIR" => joinpath(prefix, "share", "pipewire-ao"),
        "PIPEWIREAO_SIMULATOR_ROOT" => simulator_root,
    ]
    service = """
    # Generated by PipeWireAORTC.ManagementCLI.install; regenerate with the selected tooling project.
    [Unit]
    Description=PipeWireAO local management
    Requires=pipewireao-management.socket
    After=pipewireao-management.socket

    [Service]
    Type=exec
    ExecStart=$command --socket %t/pipewireao/management.sock
    $(join(("Environment=" * unit_value(key * "=" * value) for (key, value) in environment), "\n"))
    UMask=0077
    KillMode=control-group
    TimeoutStopSec=5
    Restart=no
    """
    socket = """
    # Generated by PipeWireAORTC.ManagementCLI.install; regenerate with the selected tooling project.
    [Unit]
    Description=PipeWireAO local management socket

    [Socket]
    ListenStream=%t/pipewireao/management.sock
    SocketMode=0600
    DirectoryMode=0700
    RemoveOnStop=yes
    Backlog=16

    [Install]
    WantedBy=sockets.target
    """
    return Dict(
        "pipewireao-management.service" => service, "pipewireao-management.socket" => socket
    )
end

"""Install owner activation units without activating or restarting any service.

The caller selects the installed native prefix and pinned management tooling
project. Existing units are not overwritten; the operator owns replacement and
activation. GUI processes never call this function.
"""
function install(
    prefix::AbstractString;
    project = active_project(),
    unit_directory = joinpath(
        get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "systemd", "user"
    ),
    configuration_root = ConfigurationStore.default_root(),
    root = state_root(),
    simulator_root = SimulatorConfiguration.default_root(),
)
    prefix = realpath(prefix)
    executable = joinpath(prefix, "bin", "pipewireao-management")
    isfile(executable) && (filemode(executable) & 0o111) != 0 ||
        throw(ArgumentError("install the native pipewireao-management executable first"))
    isfile(joinpath(project, "Project.toml")) ||
        throw(ArgumentError("management tooling Project.toml is missing"))
    units = unit_texts(prefix; project, configuration_root, root, simulator_root)
    directory = absolute_path(unit_directory, "unit directory")
    paths = Dict(name => joinpath(directory, name) for name in keys(units))
    any(ispath, values(paths)) && throw(
        ArgumentError(
            "management units already exist; explicit owner replacement is required"
        ),
    )
    mkpath(directory; mode = 0o700)
    for (name, text) in units
        flags =
            Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT |
            Base.Filesystem.JL_O_EXCL
        output = Base.Filesystem.open(paths[name], flags, 0o600)
        try
            write(output, text)
        finally
            close(output)
        end
    end
    return paths
end

end
