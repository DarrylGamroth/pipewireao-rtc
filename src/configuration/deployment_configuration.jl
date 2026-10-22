module DeploymentConfiguration

using JSON3, TOML
using ..Common
using ..Placement
import ..PipeWireAORTC
import ..ScienceExport
import ..NativeControlClient
import ..NativeOwnerBootstrapCodec

export DeploymentError, fail, require, digest, atomic_record, installed_paths, decode,
    validate_environment, relative_asset, valid_cpu_list, native_bootstrap,
    bootstrap_instance_key, native_heart, native_source, native_acquisition,
    validate_acquisition_arguments, validate_bootstrap_arguments,
    validate_session_runtime, profile, substitute, validate_runtime,
    selected_julia_executable, shell_quote, installed_wrappers, registered_application,
    application_environment

const MAX_CONFIG_BYTES = 16 * 1024 * 1024
const REQUIRED_KEYS = Set(["version", "name", "session", "core", "client", "placement",
    "owners", "environment", "artifacts", "cpu-latency-us"])

struct DeploymentError <: Exception
    message::String
end
Base.showerror(io::IO, error::DeploymentError) = print(io, error.message)
fail(message) = throw(DeploymentError(message))
require(condition, message) = condition || fail(message)
digest(path::AbstractString) = Common.sha256_file(path)
atomic_record(path::AbstractString, value) = Common.write_json(path, value; atomic=true)

function installed_paths(prefix::AbstractString)
    candidates = [joinpath(prefix, "lib"), joinpath(prefix, "lib64")]
    lib = joinpath(prefix, "lib")
    isdir(lib) && append!(candidates, readdir(lib; join=true))
    libraries = filter(path -> isfile(joinpath(path, "libpipewire-ao-0.3.so")), candidates)
    length(libraries) == 1 || fail("expected one installed PipeWireAO library directory in $prefix")
    library = only(libraries)
    paths = Dict("library" => library, "modules" => joinpath(library, "pipewire-ao-0.3"),
        "spa" => joinpath(library, "spa-ao-0.2"), "daemon" => joinpath(prefix, "bin/pipewire-ao"),
        "parser" => joinpath(prefix, "bin/pwao-spa-json-dump"))
    for (label, path) in paths
        ispath(path) || fail("missing installed $label: $path")
    end
    paths
end

function decode(path::AbstractString, prefix::AbstractString)
    filesize(path) <= MAX_CONFIG_BYTES || fail("deployment configuration exceeds 16 MiB")
    try
        return Common.read_json(path; maximum=MAX_CONFIG_BYTES)
    catch error
        error isa SystemError && rethrow()
        paths = installed_paths(prefix)
        env = merge(Dict(ENV), Dict("LD_LIBRARY_PATH" => paths["library"]))
        out, _, code = Common.run_checked([paths["parser"], "-N", "-R", path]; env, timeout=10)
        code == 0 || fail("installed SPA-JSON parser rejected $path")
        ncodeunits(out) <= MAX_CONFIG_BYTES || fail("decoded deployment configuration exceeds 16 MiB")
        return Common.parse_json(out)
    end
end

function validate_environment(value, label)
    require(value isa AbstractDict && all(value) do (key, item)
        key isa String && !isempty(key) && !occursin('=', key) && !occursin('\0', key) &&
            item isa String && !occursin('\0', item)
    end,
        "$label environment must map valid names to strings")
end

function relative_asset(package::AbstractString, name)
    require(name isa String && !isempty(name) && !occursin('\0', name) && !isabspath(name),
        "installed asset must be a package-relative path")
    candidate = realpath(joinpath(package, name))
    root = realpath(package)
    require(startswith(candidate, root * "/") && isfile(candidate),
        "asset escapes package or is not a file: $name")
    candidate
end

function valid_cpu_list(value)
    value isa AbstractVector || fail("process CPU envelope must be a list")
    Placement.cpu_set(value)
end

native_bootstrap(owner) = get(owner, "bootstrap-protocol", nothing) == NativeControlClient.profile_name(NativeOwnerBootstrapCodec.PROFILE)
bootstrap_instance_key(role::AbstractString) = "BOOTSTRAP_INSTANCE_" * replace(uppercase(role), "-"=>"_")

native_heart(owner) = get(owner, "control-protocol", nothing) == "pipewireao.rtc.heart/1"

native_source(owner) = get(owner, "control-protocol", nothing) == "pipewireao.source-control/1"

native_acquisition(owner) = get(owner, "control-protocol", nothing) in
    ("pipewireao.rtc.calibration-lifecycle/1", "pipewireao.rtc.correction-lifecycle/1")

function validate_acquisition_arguments(owner)
    argv = owner["argv"]
    for flag in ("--prepared-event", "--connect-request", "--connect-reply", "--quit-request",
            "--control-request", "--control-reply")
        require(!(flag in argv), "native acquisition cannot use live file controls")
    end
    for (flag, value) in (("--control-node", owner["control-node"]),
            ("--control-instance", "@SOURCE_OWNER_INSTANCE@"),
            ("--profile", owner["instrument"]), ("--remote", "@RUNTIME@/@REMOTE@"))
        indices = findall(==(flag), argv)
        require(length(indices) == 1 && only(indices) < length(argv) && argv[only(indices) + 1] == value,
            "native acquisition requires the exact $flag binding")
    end
    return nothing
end

function validate_bootstrap_arguments(owner)
    argv=owner["argv"]
    for flag in ("--prepared-event","--connect-request","--connect-reply","--quit-request",
            "--control-request","--control-reply")
        require(!any(arg->first(split(arg,'=';limit=2))==flag,argv),"native bootstrap cannot use live file controls")
    end
    for (flag,value) in (("--bootstrap-node",owner["bootstrap-node"]),
            ("--bootstrap-instance","@" * bootstrap_instance_key(owner["role"]) * "@"),
            ("--remote","@RUNTIME@/@REMOTE@"))
        indices=findall(arg->first(split(arg,'=';limit=2))==flag,argv)
        require(length(indices)==1 && argv[only(indices)]==flag && only(indices)<length(argv) && argv[only(indices)+1]==value,
            "native bootstrap requires the exact $flag binding")
    end
    if native_source(owner)
        flag="--control-node"
        indices=findall(arg->first(split(arg,'=';limit=2))==flag,argv)
        require(length(indices)==1 && argv[only(indices)]==flag && only(indices)<length(argv) &&
            argv[only(indices)+1]==owner["control-node"],"native source requires the exact --control-node binding")
        require(owner["bootstrap-node"] != owner["control-node"],"source and bootstrap nodes must differ")
    end
    thread_flags=filter(arg->startswith(arg,"--threads="),argv)
    require(length(thread_flags)==1 && occursin(r"^--threads=([2-9]|[1-9][0-9]+),0$",only(thread_flags)),
        "native bootstrap requires at least two default Julia threads and zero interactive threads")
    return nothing
end

const SESSION_PRIVATE_ENVIRONMENT = Set(["INVOCATION_ID", "NOTIFY_SOCKET", "SYSTEMD_EXEC_PID",
    "RTC_CONFIG", "WIREPLUMBER_CONFIG", "WIREPLUMBER_CONFIG_DIR",
    "WIREPLUMBER_MODULE_DIR", "WIREPLUMBER_DATA_DIR", "LD_LIBRARY_PATH",
    "PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_REMOTE", "PIPEWIREAO_REMOTE"])

"Validate the sole headless RTC executable and its exact invocation."
function validate_session_runtime(value)
    require(value isa AbstractDict && Set(keys(value)) == Set(["argv", "environment"]),
        "session-runtime requires argv and environment")
    argv = value["argv"]
    require(argv isa AbstractVector && length(argv) == 3 &&
        all(arg -> arg isa String && !occursin('\0', arg), argv) &&
        first(argv) in ("@PACKAGE@/rtc/bin/pipewireao-rtc", "@PREFIX@/bin/pipewireao-rtc") &&
        argv[2] == "-c" && argv[3] == "@RUNTIME@/rtc/rtc.conf",
        "session-runtime requires pipewireao-rtc -c @RUNTIME@/rtc/rtc.conf")
    validate_environment(value["environment"], "session-runtime")
    require(isempty(intersect(Set(keys(value["environment"])), SESSION_PRIVATE_ENVIRONMENT)),
        "session-runtime environment cannot override private session bindings")
    return nothing
end

"Resolve the required native executable from the sealed deployment contract."
function session_executable(spec, package, prefix)
    value = spec["session-runtime"]
    validate_session_runtime(value)
    expected = registered_application(spec) ? "@PREFIX@/bin/pipewireao-rtc" :
        "@PACKAGE@/rtc/bin/pipewireao-rtc"
    require(first(value["argv"]) == expected,
        "session-runtime executable does not match its registered or sealed deployment")
    return substitute(expected, Dict("PACKAGE" => package, "PREFIX" => prefix))
end

"Verify the process uses the exact prepared executable and private configuration."
function verify_session_process(pid::Integer, executable::AbstractString, config::AbstractString)
    require(basename(executable) == "pipewireao-rtc" && isabspath(executable) && isabspath(config),
        "invalid headless RTC process binding")
    observed = try
        realpath("/proc/$pid/exe") == realpath(executable) &&
            split(read("/proc/$pid/cmdline", String), '\0'; keepempty=false) ==
                [executable, "-c", config]
    catch
        false
    end
    require(observed, "session MainPID is not the exact prepared headless RTC executable")
    return nothing
end

"Explicit cold startup budget; acquisition and live-control deadlines are separate."
function startup_timeout_ms(spec::AbstractDict)
    value = get(spec, "startup-timeout-ms", 300000)
    require(value isa Integer && !(value isa Bool) && 1000 <= value <= 3600000,
        "startup-timeout-ms must be an integer in 1000:3600000")
    return Int(value)
end

"""Whether this deployment obtains its executable implementation from Julia packages."""
registered_application(spec::AbstractDict) = haskey(spec, "runtime")

"""Validate a contained, immutable application environment without resolving packages."""
function application_environment(spec::AbstractDict, package::AbstractString)
    runtime = spec["runtime"]
    require(runtime isa AbstractDict && Set(keys(runtime)) == Set(["kind", "project"]) &&
        runtime["kind"] == "registered", "runtime requires kind=registered and project")
    project = runtime["project"]
    require(project isa String && !isempty(project) && !isabspath(project) &&
        !occursin('\0', project), "runtime project must be a relative directory")
    root = realpath(package)
    environment = realpath(joinpath(root, project))
    require(environment == root || startswith(environment, root * "/"),
        "runtime project escapes the application")
    sealed = get(spec, "artifacts", Dict())
    for filename in ("Project.toml", "Manifest.toml")
        relative = normpath(joinpath(project, filename))
        file = relative_asset(root, relative)
        require(get(sealed, relative, nothing) == digest(file),
            "application environment must be sealed: $relative")
    end
    metadata = TOML.parsefile(joinpath(environment, "Project.toml"))
    direct = get(metadata, "deps", Dict())
    require(get(direct, "PipeWireAORTC", nothing) ==
        "a3e2c7da-f73f-4284-8482-36ac422b34e6", "application must depend on PipeWireAORTC")
    require(!haskey(metadata, "sources"), "registered application must not override package sources")
    manifest = TOML.parsefile(joinpath(environment, "Manifest.toml"))
    dependencies = get(manifest, "deps", nothing)
    require(dependencies isa AbstractDict && !isempty(dependencies),
        "application manifest must contain its dependency closure")
    for (name, uuid) in direct
        entries = get(dependencies, name, Any[])
        require(entries isa AbstractVector && count(entry -> entry isa AbstractDict &&
            get(entry, "uuid", nothing) == uuid, entries) == 1,
            "application manifest must resolve direct dependency $name exactly once")
    end
    for (name, entries) in dependencies
        require(entries isa AbstractVector && !isempty(entries), "invalid manifest dependency $name")
        for entry in entries
            require(entry isa AbstractDict, "invalid manifest dependency record $name")
            require(!haskey(entry, "path") && !haskey(entry, "repo-url") &&
                !haskey(entry, "repo-rev"), "application dependencies must resolve through registries")
            uuid = get(entry, "uuid", nothing)
            require(uuid isa String && occursin(r"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$", uuid),
                "invalid manifest UUID for $name")
            stdlib = joinpath(Sys.STDLIB, name, "Project.toml")
            bundled = isfile(stdlib) && get(TOML.parsefile(stdlib), "uuid", nothing) == uuid
            tree = get(entry, "git-tree-sha1", nothing)
            require(bundled || tree isa String && occursin(r"^[0-9a-f]{40}$", tree),
                "registered dependency $name requires an immutable tree hash")
            version = get(entry, "version", nothing)
            require(bundled || version isa String && tryparse(VersionNumber, version) !== nothing,
                "registered dependency $name requires a package version")
            required = get(entry, "deps", String[])
            require(required isa AbstractVector || required isa AbstractDict,
                "invalid dependency list for $name")
            names = required isa AbstractDict ? keys(required) : required
            require(all(dependency -> haskey(dependencies, dependency), names),
                "application manifest is missing a dependency of $name")
            for dependency in names
                candidates = dependencies[dependency]
                require(candidates isa AbstractVector &&
                    (required isa AbstractDict ? count(candidate -> candidate isa AbstractDict &&
                        get(candidate, "uuid", nothing) == required[dependency], candidates) == 1 :
                        length(candidates) == 1), "application manifest has an ambiguous dependency of $name")
            end
        end
    end
    return environment
end

function profile(path::AbstractString, prefix::AbstractString; legacy_export_input::Bool=false)
    value = decode(path, prefix)
    require(value isa AbstractDict && REQUIRED_KEYS ⊆ Set(keys(value)) ⊆
        union(REQUIRED_KEYS, Set(["source-owner","detector-observation","session-runtime","node-owners","startup-timeout-ms","runtime","analysis","instrument"])) && get(value, "version", nothing) === 1,
        "expected version 1 deployment with the documented fields")
    registered_application(value) && application_environment(value, dirname(path))
    startup_timeout_ms(value)
    require(value["name"] isa String && occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", value["name"]),
        "deployment name must use 1..40 lowercase letters, digits or hyphens")
    owners = value["owners"]
    require(owners isa AbstractVector && length(owners) <= 4,
        "deployment permits at most four external owners")
    require(!haskey(value,"analysis") || value["analysis"] isa AbstractVector && length(value["analysis"]) <= 8,
        "deployment analysis must be a list of at most eight entries")
    validate_environment(value["environment"], "deployment")
    roles = Set(["core", "rtc"])
    if haskey(value,"session-runtime")
        validate_session_runtime(value["session-runtime"])
        push!(roles,"session")
    end
    source_role = get(value, "source-owner", nothing)
    require(source_role === nothing || source_role isa String && !isempty(source_role),
        "source-owner must name an existing external owner")
    markers = Set{String}()
    for owner in owners
        require(owner isa AbstractDict, "external owner fields do not match the deployment contract")
        ordinary = !native_heart(owner) && !native_acquisition(owner)
        require(!ordinary || native_bootstrap(owner) || legacy_export_input,
            "ordinary owner requires native bootstrap; regenerate the deployment from its sealed artifacts")
        fields = !ordinary ? Set(["role", "argv", "environment", "control-protocol", "control-node"]) :
            native_bootstrap(owner) ? Set(["role", "argv", "environment", "bootstrap-protocol", "bootstrap-node"]) :
            Set(["role", "argv", "environment", "prepared", "connect", "connected", "quit"])
        if native_bootstrap(owner)
            node = get(owner,"bootstrap-node",nothing)
            require(node isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",node),
                "native bootstrap requires a bounded exact node name")
        end
        if native_acquisition(owner)
            push!(fields, "instrument")
            require(get(owner, "role", nothing) == source_role,
                "native acquisition lifecycle must be the selected source owner")
            require(get(owner, "instrument", nothing) in ("classic", "copper"),
                "native acquisition requires an explicit Classic or Copper instrument")
            node = get(owner, "control-node", nothing)
            require(node isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node),
                "native acquisition requires a bounded exact node name")
        end
        if native_heart(owner)
            require(get(owner, "role", nothing) == "heart", "native HEART profile requires the heart role")
            node = get(owner, "control-node", nothing)
            require(node isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$", node),
                "native HEART requires a bounded exact node name")
        end
        if source_role !== nothing && get(owner, "role", nothing) == source_role
            require(native_acquisition(owner) || native_source(owner) || legacy_export_input,
                "source owner requires a native source control profile")
            native_acquisition(owner) || union!(fields, native_source(owner) ?
                ["control-protocol", "control-node"] : ["control-request", "control-reply"])
            if native_source(owner)
                node = get(owner,"control-node",nothing)
                require(node isa String && occursin(r"^[a-zA-Z0-9_.-]{1,128}$",node),
                    "native source requires a bounded exact node name")
            end
        end
        require(Set(keys(owner)) == fields, "external owner fields do not match the deployment contract")
        role = owner["role"]
        require(role != "heart" || native_heart(owner) || legacy_export_input,
            "HEART owner requires the native control profile")
        require(role isa String && !(role in roles) && occursin(r"^[a-z][a-z0-9-]{0,31}$", role),
            "external owner role must be unique and filesystem-safe")
        push!(roles, role)
        argv = owner["argv"]
        require(argv isa AbstractVector && 1 <= length(argv) <= 256 &&
            all(arg -> arg isa String && !occursin('\0', arg), argv) && !isempty(argv[1]),
            "owner argv must be a nonempty bounded string list")
        native_acquisition(owner) && validate_acquisition_arguments(owner)
        native_bootstrap(owner) && validate_bootstrap_arguments(owner)
        validate_environment(owner["environment"], "owner $role")
        names = Set{String}()
        marker_keys = native_heart(owner) || native_acquisition(owner) || native_bootstrap(owner) ? String[] : ["prepared", "connect", "connected", "quit"]
        role == source_role && !native_source(owner) && !native_acquisition(owner) &&
            append!(marker_keys, ["control-request", "control-reply"])
        for key in marker_keys
            marker = owner[key]
            require(marker isa String && !(marker in (".", "..")) &&
                occursin(r"^[a-zA-Z0-9_.-]{1,64}$", marker), "owner $key must be a marker basename")
            push!(names, marker)
        end
        require(length(names) == length(marker_keys) && isempty(intersect(names, markers)),
            "owner markers must be distinct")
        union!(markers, names)
    end
    require(source_role === nothing || source_role in (owner["role"] for owner in owners),
        "source-owner must name an existing external owner")
    require(!haskey(value,"detector-observation") || value["detector-observation"] isa Bool,
        "detector-observation must be a Boolean")
    require(!get(value,"detector-observation",false) || source_role !== nothing &&
        native_source(only(filter(owner->owner["role"] == source_role,owners))),
        "detector observation requires an admitted native source owner")
    reserved = union(roles, Set(["control.sock", "native-control.sock", "native-prefix", "julia-depot"]))
    require(isempty(intersect(markers, reserved)), "owner markers conflict with deployment runtime paths")
    source = source_role === nothing ? nothing : only(filter(owner -> owner["role"] == source_role, owners))
    if source !== nothing && !native_source(source) && !native_acquisition(source)
        staging = splitext(source["control-request"])[1] * ".new"
        require(!(staging in markers || staging in reserved), "source request staging path conflicts with runtime paths")
    end
    placements = value["placement"]
    require(placements isa AbstractDict && Set(keys(placements)) == roles,
        "each owned process requires an explicit placement contract")
    for (role, placement) in placements
        require(placement isa AbstractDict && Set(keys(placement)) ==
            Set(["cpus", "leader-cpu", "rt-priority", "threads", "locked-bytes"]),
            "invalid placement contract for $role")
        envelope = valid_cpu_list(placement["cpus"])
        require(typeof(placement["leader-cpu"]) === Int && placement["leader-cpu"] in envelope,
            "process leader CPU must belong to its declared envelope")
        priority = placement["rt-priority"]
        require(typeof(priority) === Int && 0 <= priority <= 99,
            "RT priority must be an integer in 0..99")
        require(typeof(placement["locked-bytes"]) === Int && placement["locked-bytes"] >= 0,
            "locked-bytes must be nonnegative")
        threads = placement["threads"]
        require(threads isa AbstractVector && length(threads) <= 128,
            "thread requirements must be a bounded list")
        for thread in threads
            require(thread isa AbstractDict && Set(["cpus", "policy", "priority", "count"]) ⊆ Set(keys(thread)) ⊆
                Set(["cpus", "policy", "priority", "count", "name"]), "invalid required thread fields")
            require(thread["cpus"] isa AbstractVector, "required thread CPUs must be a list")
            require(Placement.cpu_set(thread["cpus"]) ⊆ envelope, "required thread exceeds process envelope")
            require(thread["policy"] in ("fifo", "other") && typeof(thread["count"]) === Int &&
                typeof(thread["priority"]) === Int && 1 <= thread["count"] <= 128 &&
                thread["priority"] == (thread["policy"] == "fifo" ? priority : 0),
                "invalid required thread policy/count")
            require(!haskey(thread, "name") || thread["name"] isa String &&
                !isempty(thread["name"]) && !occursin('\0', thread["name"]),
                "required thread name must be a nonempty string")
        end
    end
    latency = value["cpu-latency-us"]
    require(latency === nothing || typeof(latency) === Int && 0 <= latency <= typemax(Int32),
        "cpu-latency-us must be null or a nonnegative Int32")
    client_roles = isempty(get(value, "analysis", [])) ? roles : union(roles, Set(["analysis"]))
    require(value["client"] isa AbstractDict && Set(keys(value["client"])) == client_roles,
        "each owned process and optional analysis require an explicit client configuration")
    for name in values(value["client"])
        relative_asset(dirname(path), name)
    end
    relative_asset(dirname(path), value["session"])
    relative_asset(dirname(path), value["core"])
    require(value["artifacts"] isa AbstractDict, "deployment artifacts must be a path/hash mapping")
    for (name, sha) in value["artifacts"]
        asset = relative_asset(dirname(path), name)
        require(sha isa String && occursin(r"^[0-9a-f]{64}$", sha) && digest(asset) == sha,
            "deployment artifact hash mismatch: $name")
    end
    if haskey(value, "node-owners")
        mapping = value["node-owners"]
        require(mapping isa AbstractDict && all(key isa String && role isa String
            for (key, role) in mapping), "node-owners must map exact node names to owner roles")
        session = decode(relative_asset(dirname(path), value["session"]), prefix)
        nodes = String[]
        fgn = false
        parameters = false
        for section in ("sources", "graphs", "sinks")
            entries = get(session, section, nothing)
            require(entries isa AbstractVector, "session $section must be a list for node-owners")
            for item in entries
                require(item isa AbstractDict && get(item, "node.name", nothing) isa String,
                    "node-owners requires declared node.name for every endpoint")
                push!(nodes, item["node.name"])
                fgn |= section == "graphs" && get(item, "factory", nothing) == "pipewireao.fgn-native"
                parameters |= section == "sources" &&
                    get(item, "factory", nothing) == "pipewireao.runtime-parameter"
            end
        end
        roles = Set(owner["role"] for owner in owners)
        fgn && push!(roles, "fgn")
        parameters && push!(roles, "parameters")
        core = decode(relative_asset(dirname(path), value["core"]), prefix)
        core_nodes = Set{String}()
        for item in get(core, "context.objects", Any[])
            item isa AbstractDict || continue
            args = get(item, "args", nothing)
            args isa AbstractDict || continue
            node = get(args, "node.name", nothing)
            node isa String && push!(core_nodes, node)
        end
        # A queue module creates its capture/playback streams through the
        # private core's own native client, rather than a context SPA object.
        # Exact names must still originate in the sealed core configuration;
        # native admission verifies the bound client's process identity.
        for item in get(core, "context.modules", Any[])
            item isa AbstractDict && get(item,"name",nothing) == "libpipewire-module-queue" || continue
            args = get(item,"args",nothing)
            args isa AbstractDict || continue
            for key in ("capture.props","playback.props")
                properties = get(args,key,nothing)
                properties isa AbstractDict || continue
                node = get(properties,"node.name",nothing)
                node isa String && push!(core_nodes,node)
            end
        end
        !isempty(core_nodes) && push!(roles, "core")
        require(length(unique(nodes)) == length(nodes) && Set(keys(mapping)) == Set(nodes) &&
            all(role in roles for role in values(mapping)),
            "node-owners must cover each declared node once with a declared owner role")
        for section in ("sources", "graphs", "sinks"), item in session[section]
            if mapping[item["node.name"]] == "core"
                require(item["node.name"] in core_nodes,
                    "core-mapped node must have an exact private core context object or queue stream")
            end
            if section == "graphs" && get(item, "factory", nothing) == "pipewireao.fgn-native"
                require(mapping[item["node.name"]] == "fgn", "FGN graph must map to its own host")
            elseif section == "sources" &&
                    get(item, "factory", nothing) == "pipewireao.runtime-parameter"
                require(mapping[item["node.name"]] == "parameters",
                    "runtime parameter source must map to the parameters owner")
            end
        end
    end
    PipeWireAORTC.Analysis.validate_deployment(value, path, prefix)
    if haskey(value,"instrument")
        asset=relative_asset(dirname(path),value["instrument"])
        haskey(value["artifacts"],value["instrument"]) || fail("instrument definition must be sealed")
        PipeWireAORTC.InstrumentDefinition.load(asset)
    end
    Dict{String,Any}(value)
end

function substitute(value::AbstractString, bindings::AbstractDict; quoted=false)
    result = String(value)
    for (name, replacement) in bindings
        escaped = quoted ? String(JSON3.write(replacement))[2:end-1] : string(replacement)
        result = replace(result, "@$name@" => escaped)
    end
    occursin(r"@[A-Z_]+@", result) && fail("unresolved deployment binding in $(first(result, min(length(result), 200)))")
    result
end

function validate_runtime(root::AbstractString)
    isfile(joinpath(root, "src", "PipeWireAORTC.jl")) ||
        fail("unsupported legacy include-loaded deployment runtime; preserve this sealed SDK and use its original launcher, or export a new SDK with the named package")
    for name in ScienceExport.RUNTIME_ENTRIES
        expected = joinpath(ScienceExport.package_root(), name)
        installed = joinpath(root, name)
        complete = isdir(expected) ? isdir(installed) : isfile(installed)
        complete && !islink(installed) ||
            fail("installed Julia deployment runtime is incomplete: $name")
    end
    for name in ("test/Project.toml", "test/runtests.jl")
        isfile(joinpath(root, name)) && !islink(joinpath(root, name)) ||
            fail("installed Julia deployment runtime is incomplete: $name")
    end
    metadata = TOML.parsefile(joinpath(root, "Project.toml"))
    owner = parentmodule(@__MODULE__)
    get(metadata, "name", nothing) == "PipeWireAORTC" &&
        get(metadata, "uuid", nothing) == string(Base.PkgId(owner).uuid) ||
        fail("installed Julia deployment runtime has an unsupported package identity")
    version = tryparse(VersionNumber, get(metadata, "version", ""))
    version !== nothing && version.major == Base.pkgversion(owner).major &&
        version.minor == Base.pkgversion(owner).minor ||
        fail("installed Julia deployment runtime version is unsupported by this installer")
    source = joinpath(ScienceExport.package_root(), "src")
    for (parent, _, files) in walkdir(source)
        for name in files
            endswith(name, ".jl") || continue
            relative = relpath(joinpath(parent, name), source)
            installed = joinpath(root, "src", relative)
            isfile(installed) && !islink(installed) ||
                fail("installed Julia deployment runtime is incomplete: src/$relative")
        end
    end
    resources = joinpath(root, "assets", "deployment")
    for directory in ("hil", "templates")
        for (parent, dirs, files) in walkdir(joinpath(ScienceExport.resource_root(), directory))
            filter!(name -> !(name in ("__pycache__", ".git")) && !startswith(name, "test_"), dirs)
            for name in files
                (startswith(name, "test_") || endswith(name, ".py")) && continue
                relative = relpath(joinpath(parent, name), ScienceExport.resource_root())
                isfile(joinpath(resources, relative)) && !islink(joinpath(resources, relative)) ||
                    fail("installed Julia deployment resources are incomplete: $relative")
            end
        end
    end
    for name in (ScienceExport.RESOURCE_ENTRYPOINTS..., "pipewireao-session@.service.in")
        isfile(joinpath(resources, name)) && !islink(joinpath(resources, name)) ||
            fail("installed Julia deployment resources are incomplete: $name")
    end
    return root
end

function selected_julia_executable(path::AbstractString)
    isabspath(path) && !occursin('\0', path) && !occursin('\n', path) &&
        !occursin('\r', path) || fail("--julia-executable must be an absolute executable path")
    isfile(path) && isexecutable(path) || fail("selected Julia executable is missing or not executable: $path")
    executable = realpath(path)
    probe = try
        Common.run_checked([executable, "--startup-file=no", "--history-file=no", "-e",
            "print(VERSION, '\\n', Base.julia_cmd().exec[1])"];
            timeout=15, maximum_output_bytes=4096)
    catch error
        fail("cannot validate selected Julia executable $path: $(sprint(showerror, error))")
    end
    fields = split(strip(probe.stdout), '\n')
    version = tryparse(VersionNumber, first(fields))
    probe.returncode == 0 && version !== nothing && v"1.12" <= version < v"2" ||
        fail("selected Julia executable must run Julia >= 1.12 and < 2: $path")
    length(fields) == 2 && isabspath(fields[2]) && isfile(fields[2]) && isexecutable(fields[2]) ||
        fail("selected Julia executable did not report its absolute runtime executable: $path")
    # Pin the managed runtime itself when selection was through juliaup.
    return realpath(fields[2])
end

shell_quote(value::AbstractString) = "'" * replace(value, "'" => "'\"'\"'") * "'"

const INSTALLED_ENTRYPOINTS = Dict("rtc-calibrate" => "CalibrationCLI")

function installed_wrappers(julia::AbstractString)
    executable = shell_quote(julia)
    scripts = Dict{String,String}()
    for (name, owner) in INSTALLED_ENTRYPOINTS
        scripts[name] = "#!/bin/sh\njulia_dir=\"\$(dirname \"\$0\")/../julia\"\n" *
            "exec $executable --startup-file=no --project=\"\$julia_dir\" -e " *
            "'using PipeWireAORTC; " *
            "exit(PipeWireAORTC.$owner.main(ARGS))' -- \"\$@\"\n"
    end
    return scripts
end

end
